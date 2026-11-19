import Foundation

// MARK: - Model

/// One image found inside a Xiaohongshu note.
struct ImageItem: Identifiable {
    let id: String          // e.g. "1", "2", ... (index inside the note)
    let imageURL: URL       // original-quality image (sns-img-bd, full resolution)
    let fallbackURL: URL    // 1080px web version (urlDefault), used if the original fails
    let width: Int
    let height: Int
    /// Motion clip for a Live Photo (imageList[].livePhoto == true).
    /// nil for ordinary static images. The clip is the ~2s mp4 at
    /// imageList[].stream.h264[0].masterUrl.
    let livePhotoClipURL: URL?
}

/// One video found inside a Xiaohongshu note (a video note has one).
struct VideoItem: Identifiable {
    let id: String          // "video"
    let videoURL: URL       // original-quality video (sns-video-bd origin key)
    let fallbackURL: URL    // stream masterUrl, used if the origin fails
    let coverURL: URL?      // video cover image (imageList[0].urlDefault)
    let width: Int
    let height: Int
    let durationMs: Int
    let title: String
}

/// Everything parsed from one note: its images and (for a video note) its video.
/// `title` is the note headline; `bodyText` is the full body text (desc),
/// kept so the whole article can be handed to another app (e.g. Ctrip).
struct NoteMedia {
    let images: [ImageItem]
    let video: VideoItem?
    let title: String
    let bodyText: String
}

// MARK: - Errors

enum ResolverError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case emptyResponse
    case stateNotFound
    case stateParseFailed
    case noteNotFound
    case noMedia

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接无效，请粘贴完整的小红书笔记链接"
        case .httpError(let code): return "请求失败（HTTP \(code)），链接可能已过期，请重新复制链接再试"
        case .emptyResponse: return "没有取到笔记内容，请重新复制链接再试"
        case .stateNotFound: return "没有解析到笔记数据，链接可能已过期，请重新复制链接再试"
        case .stateParseFailed: return "笔记数据解析失败，请重新复制链接再试"
        case .noteNotFound: return "没有找到这篇笔记，请检查链接是否正确"
        case .noMedia: return "这篇笔记里没有图片或视频"
        }
    }
}

// MARK: - Resolver

/// Fetches a Xiaohongshu note page and extracts ALL its images.
///
/// The note page must be fetched with a desktop Chrome User-Agent and NO
/// Referer header. Sending a Referer makes Xiaohongshu redirect to /login.
/// The page follows a redirect chain (xiaohongshu.com/explore -> 302
/// rednote.com/explore -> 301 rednote.com/discovery/item/<id>) and sets a
/// cookie at each hop, so cookies must be kept across redirects.
struct ImageResolver {

    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

    /// URLSession that keeps cookies across redirects (shared cookie storage).
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        // Do not set a default Referer anywhere; URLSession does not add one
        // for data tasks unless the request carries one.
        return URLSession(configuration: config)
    }

    /// Fetch the note page HTML for a pasted explore link.
    ///
    /// The pasted text may contain more than the link itself (Xiaohongshu
    /// share text often has a title in front of the URL), so the first
    /// http(s) URL inside the text is extracted instead of requiring the
    /// whole string to be a URL.
    static func fetchNoteHTML(link: String) async throws -> String {
        guard let url = extractLinkURL(from: link) else {
            throw ResolverError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-us,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        // NOTE: intentionally no Referer header.
        request.setValue("close", forHTTPHeaderField: "Connection")

        let session = makeSession()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResolverError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ResolverError.httpError(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw ResolverError.emptyResponse
        }
        return html
    }

    /// Parse the note page HTML and return ALL images and (for a video
    /// note) the video it contains.
    static func parseMedia(from html: String) throws -> NoteMedia {
        guard let rawState = extractInitialState(from: html) else {
            throw ResolverError.stateNotFound
        }
        let jsonString = sanitizeJSObjectLiteral(rawState)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw ResolverError.stateParseFailed
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: jsonData, options: [])
        } catch {
            throw ResolverError.stateParseFailed
        }
        guard
            let root = parsed as? [String: Any],
            let noteRoot = root["note"] as? [String: Any],
            let detailMap = noteRoot["noteDetailMap"] as? [String: Any],
            let firstDetail = detailMap.values.first as? [String: Any],
            let note = firstDetail["note"] as? [String: Any]
        else {
            throw ResolverError.noteNotFound
        }

        // Video (a video note has one). Parsed first so the cover image
        // (imageList[0]) can be dropped from the image list below.
        let video = parseVideo(from: note)

        var items: [ImageItem] = []
        if let imageList = note["imageList"] as? [[String: Any]] {
            // For a video note, imageList[0] is just the video cover —
            // skip it so the cover does not also appear as "图片 1".
            let startIndex = video == nil ? 0 : 1
            for (offset, image) in imageList.enumerated().dropFirst(startIndex) {
                guard let imageString = image["urlDefault"] as? String,
                      let fallbackURL = URL(string: httpsURL(imageString))
                else { continue }
                // Original quality: rebuild the CDN URL from the image's fileId.
                // The web urlDefault is capped at 1080px; the same file on
                // sns-img-bd with imageView2 w/0 returns the full-resolution
                // original as a JPEG. Falls back to urlDefault when the fileId
                // cannot be derived.
                let imageURL = originalURL(from: imageString) ?? fallbackURL
                let width = (image["width"] as? NSNumber)?.intValue ?? 0
                let height = (image["height"] as? NSNumber)?.intValue ?? 0
                // Live Photo: the motion clip lives in this image's own
                // stream (imageList[].stream.h264[0].masterUrl, ~2s mp4).
                let livePhotoClipURL: URL?
                if (image["livePhoto"] as? Bool) == true {
                    livePhotoClipURL = bestStreamURL(from: image["stream"])
                } else {
                    livePhotoClipURL = nil
                }
                items.append(ImageItem(
                    id: "\(offset + 1)",
                    imageURL: imageURL,
                    fallbackURL: fallbackURL,
                    width: width,
                    height: height,
                    livePhotoClipURL: livePhotoClipURL
                ))
            }
        }
        guard !items.isEmpty || video != nil else { throw ResolverError.noMedia }
        let title = (note["title"] as? String) ?? ""
        let bodyText = (note["desc"] as? String) ?? ""
        return NoteMedia(images: items, video: video, title: title, bodyText: bodyText)
    }

    /// Parse the video out of a note dictionary. Returns nil for an image
    /// note (no `video` field) or when no playable URL can be found.
    /// Prefers the original-quality file (consumer.originVideoKey on
    /// sns-video-bd); falls back to the best stream masterUrl.
    private static func parseVideo(from note: [String: Any]) -> VideoItem? {
        guard let video = note["video"] as? [String: Any] else { return nil }
        let media = video["media"] as? [String: Any]

        // Stream URLs, largest first.
        var streams = collectStreamURLs(from: media?["stream"])
        streams.sort { ($0.width * $0.height) > ($1.width * $1.height) }

        // Original: consumer.originVideoKey -> sns-video-bd.
        var originURL: URL? = nil
        if let consumer = video["consumer"] as? [String: Any],
           let key = consumer["originVideoKey"] as? String, !key.isEmpty {
            originURL = URL(string: "https://sns-video-bd.xhscdn.com/\(key)")
        }
        guard let fallback = streams.first,
              let fallbackURL = URL(string: httpsURL(fallback.url))
        else {
            // No stream at all; the origin alone is still playable.
            guard let origin = originURL else { return nil }
            return makeVideoItem(note: note, media: media, videoURL: origin, fallbackURL: origin)
        }
        let videoURL = originURL ?? fallbackURL
        return makeVideoItem(note: note, media: media, videoURL: videoURL, fallbackURL: fallbackURL)
    }

    /// Collect stream URLs from a `stream` value, which can be an array
    /// or an object keyed by codec ({h264: [...], h265: [...]}). Each
    /// entry gives its masterUrl (or first backup URL) and dimensions.
    private static func collectStreamURLs(from rawStream: Any?) -> [(url: String, width: Int, height: Int)] {
        var streams: [(url: String, width: Int, height: Int)] = []
        guard let rawStream else { return streams }
        var list: [[String: Any]] = []
        if let arr = rawStream as? [[String: Any]] {
            list = arr
        } else if let dict = rawStream as? [String: Any] {
            for value in dict.values {
                if let arr = value as? [[String: Any]] { list += arr }
            }
        }
        for s in list {
            let url = (s["masterUrl"] as? String)
                ?? (s["backupUrls"] as? [String])?.first
            guard let url, !url.isEmpty else { continue }
            streams.append((
                url: url,
                width: (s["width"] as? NSNumber)?.intValue ?? 0,
                height: (s["height"] as? NSNumber)?.intValue ?? 0
            ))
        }
        return streams
    }

    /// The best stream URL from a `stream` value (largest first), or nil
    /// when there is no usable stream. Used for Live Photo motion clips.
    private static func bestStreamURL(from rawStream: Any?) -> URL? {
        var streams = collectStreamURLs(from: rawStream)
        streams.sort { ($0.width * $0.height) > ($1.width * $1.height) }
        guard let first = streams.first else { return nil }
        return URL(string: httpsURL(first.url))
    }

    private static func makeVideoItem(
        note: [String: Any],
        media: [String: Any]?,
        videoURL: URL,
        fallbackURL: URL
    ) -> VideoItem {
        // Cover: imageList[0].urlDefault, or the video's own cover.
        var coverURL: URL? = nil
        if let imageList = note["imageList"] as? [[String: Any]],
           let coverString = imageList.first?["urlDefault"] as? String {
            coverURL = URL(string: httpsURL(coverString))
        } else if let coverString = media?["cover"] as? String {
            coverURL = URL(string: httpsURL(coverString))
        }
        let durationMs = (media?["duration"] as? NSNumber)?.intValue ?? 0
        let title = (note["title"] as? String) ?? (note["desc"] as? String) ?? "小红书视频"
        // Width/height from the stream are lost here; keep the note's dims.
        let width = (note["width"] as? NSNumber)?.intValue ?? 0
        let height = (note["height"] as? NSNumber)?.intValue ?? 0
        return VideoItem(
            id: "video",
            videoURL: videoURL,
            fallbackURL: fallbackURL,
            coverURL: coverURL,
            width: width,
            height: height,
            durationMs: durationMs,
            title: title
        )
    }

    /// Convenience: fetch a link and return its images and video in one call.
    static func resolve(link: String) async throws -> NoteMedia {
        let html = try await fetchNoteHTML(link: link)
        return try parseMedia(from: html)
    }

    // MARK: - Helpers

    /// Find the first http(s) URL inside pasted text and return it as a URL.
    /// Share text often has a title in front of the link, and may append
    /// punctuation after it, so the URL is taken up to the first whitespace
    /// and trailing punctuation is trimmed. Returns nil when no URL is found.
    static func extractLinkURL(from text: String) -> URL? {
        guard let range = text.range(of: "https?://", options: .regularExpression) else {
            return nil
        }
        var urlString = String(text[range.lowerBound...])
        if let ws = urlString.firstIndex(where: { $0.isWhitespace }) {
            urlString = String(urlString[..<ws])
        }
        // Trim punctuation that share text often appends after the link.
        while let last = urlString.last,
              ".,;:!?。！？；：、）)】]}」”\"'".contains(last) {
            urlString.removeLast()
        }
        guard !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    /// The note page's image CDN URLs are http://. Upgrade to https://
    /// so App Transport Security never blocks them.
    private static func httpsURL(_ urlString: String) -> String {
        if urlString.hasPrefix("http://") {
            return "https://" + urlString.dropFirst("http://".count)
        }
        return urlString
    }

    /// Build the original-quality image URL from a urlDefault string.
    ///
    /// urlDefault points at sns-webpic-qc with a processing suffix
    /// (!nd_dft_wlteh_webp_3) and is capped at 1080px wide. The same file
    /// lives on sns-img-bd under its fileId; requesting it with
    /// imageView2/2/w/0/format/jpg returns the full-resolution original
    /// as a JPEG. The fileId is the path after the date/hash directories,
    /// with the !suffix stripped (it may itself contain a prefix such as
    /// notes_pre_post/ or spectrum/). Returns nil when the fileId cannot
    /// be derived, in which case the caller falls back to urlDefault.
    private static func originalURL(from urlDefault: String) -> URL? {
        var path = urlDefault
        // Strip the scheme and host, keeping only the path.
        if let schemeRange = path.range(of: "://") {
            path = String(path[schemeRange.upperBound...])
        }
        if let slash = path.firstIndex(of: "/") {
            path = String(path[slash...])
        } else {
            return nil
        }
        let segments = path.split(separator: "/").map(String.init)
        // Path is /<date>/<hash>/<fileId>[...] — fileId is segment 2 onward.
        guard segments.count >= 3 else { return nil }
        var fileId = segments[2...].joined(separator: "/")
        if let bang = fileId.firstIndex(of: "!") {
            fileId = String(fileId[..<bang])
        }
        guard !fileId.isEmpty else { return nil }
        return URL(string: "https://sns-img-bd.xhscdn.com/\(fileId)?imageView2/2/w/0/format/jpg")
    }

    /// Extract the raw `window.__INITIAL_STATE__ = {...}` object literal text.
    /// Brace matching is string-aware so braces inside quoted strings are ignored.
    private static func extractInitialState(from html: String) -> String? {
        guard let markerRange = html.range(of: "window.__INITIAL_STATE__") else {
            return nil
        }
        var cursor = markerRange.upperBound
        // Find the '=' then the opening '{'.
        guard let eqIndex = html[cursor...].firstIndex(of: "=") else { return nil }
        cursor = html.index(after: eqIndex)
        guard let openIndex = html[cursor...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString: Character? = nil
        var escaped = false
        var i = openIndex
        while i < html.endIndex {
            let ch = html[i]
            if let quote = inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == quote {
                    inString = nil
                }
            } else {
                if ch == "\"" || ch == "'" || ch == "`" {
                    inString = ch
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(html[openIndex...i])
                    }
                }
            }
            i = html.index(after: i)
        }
        return nil
    }

    /// Sanitize a JavaScript object literal so it parses as JSON.
    /// __INITIAL_STATE__ is a JS object literal, not JSON. It can contain:
    /// `undefined`, `new Set([...])`, `new Set([])`, `new Map([])`,
    /// `new Date(...)`. Each is replaced with its JSON equivalent.
    private static func sanitizeJSObjectLiteral(_ raw: String) -> String {
        var result = raw
        // new Set([...]) -> [...]  (also covers new Set([]) -> [])
        result = replaceConstructorCall(in: result, name: "Set") { inner in inner }
        // new Map([]) -> {}  (the data only ever uses an empty Map)
        result = result.replacingOccurrences(
            of: "new Map([])", with: "{}"
        )
        // new Date(...) -> null
        result = replaceConstructorCall(in: result, name: "Date") { _ in "null" }
        // Bare undefined -> null (word boundary, so identifiers like
        // "someUndefined" are not touched).
        if let regex = try? NSRegularExpression(pattern: "\\bundefined\\b") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: "null"
            )
        }
        return result
    }

    /// Find `new <name>(...)` calls and replace each with `replacement(inner)`.
    /// Parenthesis matching is string-aware.
    private static func replaceConstructorCall(
        in text: String,
        name: String,
        replacement: (String) -> String
    ) -> String {
        var output = ""
        var cursor = text.startIndex
        let token = "new \(name)("
        while let found = text[cursor...].range(of: token) {
            output += text[cursor..<found.lowerBound]
            let innerStart = found.upperBound
            // Find the matching ')' for this '('.
            var depth = 1
            var inString: Character? = nil
            var escaped = false
            var i = innerStart
            var closeIndex: String.Index? = nil
            while i < text.endIndex {
                let ch = text[i]
                if let quote = inString {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == quote {
                        inString = nil
                    }
                } else {
                    if ch == "\"" || ch == "'" || ch == "`" {
                        inString = ch
                    } else if ch == "(" {
                        depth += 1
                    } else if ch == ")" {
                        depth -= 1
                        if depth == 0 {
                            closeIndex = i
                            break
                        }
                    }
                }
                i = text.index(after: i)
            }
            guard let close = closeIndex else {
                // Unbalanced; keep the rest as-is.
                output += text[found.lowerBound...]
                return output
            }
            let inner = String(text[innerStart..<close])
            output += replacement(inner)
            cursor = text.index(after: close)
        }
        output += text[cursor...]
        return output
    }
}
