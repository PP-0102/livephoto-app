import Foundation

// MARK: - Douyin resolver
//
// Resolves a Douyin share link (video or 图文 note) into the same
// NoteMedia the Xiaohongshu resolver returns, so the rest of the app
// (saver, UI) works unchanged.
//
// How it works (verified 2026-11-15 on real videos):
// 1. The 19-digit aweme_id is taken from the link (/video/<id> or
//    /note/<id>), or from the redirect target of a v.douyin.com short link.
// 2. A ttwid cookie is registered once per app launch by POSTing to
//    ttwid.bytedance.com/ttwid/union/register/ (no login, no signing;
//    the token is issued by ByteDance and lasts ~1 year). The share page
//    only returns its SSR data (videoInfoRes) when a real ttwid is sent.
// 3. GET https://www.iesdouyin.com/share/video/<id>/ (or /share/note/)
//    with `Cookie: ttwid=<token>` and a mobile Safari User-Agent.
//    The HTML embeds window._ROUTER_DATA; loaderData["video_(id)/page"]
//    (or the note equivalent) holds videoInfoRes.item_list[0].
// 4. The no-watermark video is built from video.play_addr.uri:
//    https://aweme.snssdk.com/aweme/v1/play/?video_id=<uri>&ratio=1080p&line=0
//    (/play/ = no watermark, /playwm/ = watermarked). ratio=1080p
//    auto-downgrades when the source is 720p. Fallback is ratio=720p.
//    For 图文 notes the images array gives the original image URLs.

struct DouyinResolver {

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1"

    /// ttwid for this app launch. Registered lazily on first use.
    private static var cachedTtwid: String? = nil

    /// Resolve a pasted Douyin link (or share text containing one) into
    /// the note's images and/or video.
    static func resolve(link: String) async throws -> NoteMedia {
        guard let url = ImageResolver.extractLinkURL(from: link) else {
            throw ResolverError.invalidURL
        }
        let (awemeID, isNote) = try await extractAwemeID(from: url)
        var html: String
        do {
            html = try await fetchSharePage(awemeID: awemeID, isNote: isNote)
        } catch ResolverError.stateNotFound {
            // The ttwid may have expired or been rejected; register a fresh
            // one and retry once.
            cachedTtwid = nil
            html = try await fetchSharePage(awemeID: awemeID, isNote: isNote)
        }
        return try parseMedia(from: html)
    }

    // MARK: - aweme_id

    /// Get the 19-digit aweme_id and whether the link is a note (图文)
    /// rather than a video. A v.douyin.com short link is followed to its
    /// redirect target first; a douyin.com/video/<id> or /note/<id> link
    /// carries the id directly.
    private static func extractAwemeID(from url: URL) async throws -> (String, Bool) {
        let urlString = url.absoluteString
        if let id = firstAwemeID(in: urlString) {
            return (id, urlString.contains("/note/"))
        }
        // Short link (or any link without an id in it): follow redirects
        // and read the id from the final URL.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let finalURL = response.url?.absoluteString,
              let id = firstAwemeID(in: finalURL) else {
            throw ResolverError.invalidURL
        }
        return (id, finalURL.contains("/note/") || finalURL.contains("/share/note/"))
    }

    /// The first run of 19 digits in a string (Douyin video/note ids are
    /// 19 digits long).
    private static func firstAwemeID(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\d{19}") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let idRange = Range(match.range, in: text) else { return nil }
        return String(text[idRange])
    }

    // MARK: - ttwid

    /// Register a ttwid with ByteDance (no login). Returns the raw token
    /// (URL-decoded). Cached for the rest of the app launch.
    private static func registerTtwid() async throws -> String {
        if let cached = cachedTtwid { return cached }
        let body: [String: Any] = [
            "region": "cn",
            "aid": 1768,
            "needFid": false,
            "service": "www.douyin.com",
            "migrate_info": ["ticket": "", "source": "node"],
            "cbUrlProtocol": "https",
            "union": true,
        ]
        var request = URLRequest(url: URL(string: "https://ttwid.bytedance.com/ttwid/union/register/")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let token = setCookie
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "ttwid=", with: "")
                .removingPercentEncoding,
              !token.isEmpty
        else {
            throw ResolverError.stateNotFound
        }
        cachedTtwid = token
        return token
    }

    // MARK: - Share page

    /// Fetch the iesdouyin share page for an aweme_id, with the ttwid cookie.
    private static func fetchSharePage(awemeID: String, isNote: Bool) async throws -> String {
        let ttwid = try await registerTtwid()
        let kind = isNote ? "note" : "video"
        let url = URL(string: "https://www.iesdouyin.com/share/\(kind)/\(awemeID)/")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("ttwid=\(ttwid)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResolverError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ResolverError.httpError(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw ResolverError.emptyResponse
        }
        guard html.contains("videoInfoRes") || html.contains("noteInfoRes") else {
            throw ResolverError.stateNotFound
        }
        return html
    }

    // MARK: - Parse

    /// Parse the share page HTML into the note's images and/or video.
    /// window._ROUTER_DATA is plain JSON (unlike Xiaohongshu's JS literal).
    static func parseMedia(from html: String) throws -> NoteMedia {
        guard let rawJSON = extractRouterData(from: html),
              let jsonData = rawJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
              let loaderData = root["loaderData"] as? [String: Any]
        else {
            throw ResolverError.stateParseFailed
        }
        // Find the page entry carrying the item list: video_(id)/page has
        // videoInfoRes, note_(id)/page has noteInfoRes. Search all entries
        // so the exact key does not matter.
        var item: [String: Any]? = nil
        for value in loaderData.values {
            guard let page = value as? [String: Any] else { continue }
            for key in ["videoInfoRes", "noteInfoRes"] {
                if let info = page[key] as? [String: Any],
                   let items = info["item_list"] as? [[String: Any]],
                   let first = items.first {
                    item = first
                    break
                }
            }
            if item != nil { break }
        }
        guard let note = item else { throw ResolverError.noteNotFound }

        let video = parseVideo(from: note)

        var images: [ImageItem] = []
        if let imageList = note["images"] as? [[String: Any]] {
            for (index, image) in imageList.enumerated() {
                guard let urlList = image["url_list"] as? [String],
                      let first = urlList.first,
                      let imageURL = URL(string: first)
                else { continue }
                let fallbackURL = URL(string: urlList.count > 1 ? urlList[1] : first) ?? imageURL
                let width = (image["width"] as? NSNumber)?.intValue ?? 0
                let height = (image["height"] as? NSNumber)?.intValue ?? 0
                images.append(ImageItem(
                    id: "\(index + 1)",
                    imageURL: imageURL,
                    fallbackURL: fallbackURL,
                    width: width,
                    height: height,
                    livePhotoClipURL: nil
                ))
            }
        }
        guard !images.isEmpty || video != nil else { throw ResolverError.noMedia }
        // Douyin has no separate headline; the desc is both title and body.
        let text = (note["desc"] as? String) ?? ""
        return NoteMedia(images: images, video: video, title: text, bodyText: text)
    }

    /// Build the video item from a Douyin item dictionary.
    /// Original = constructed /play/ URL at 1080p (auto-downgrades for
    /// 720p sources); fallback = the same URL at 720p.
    private static func parseVideo(from note: [String: Any]) -> VideoItem? {
        guard let video = note["video"] as? [String: Any],
              let playAddr = video["play_addr"] as? [String: Any],
              let uri = playAddr["uri"] as? String, !uri.isEmpty
        else { return nil }
        let videoURL = URL(string: "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri)&ratio=1080p&line=0")!
        let fallbackURL = URL(string: "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri)&ratio=720p&line=0")!
        var coverURL: URL? = nil
        if let cover = video["cover"] as? [String: Any],
           let urlList = cover["url_list"] as? [String],
           let first = urlList.first {
            coverURL = URL(string: first)
        }
        let durationMs = (video["duration"] as? NSNumber)?.intValue ?? 0
        let width = (video["width"] as? NSNumber)?.intValue ?? 0
        let height = (video["height"] as? NSNumber)?.intValue ?? 0
        let title = (note["desc"] as? String) ?? "抖音视频"
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

    /// Extract the raw `window._ROUTER_DATA = {...}` JSON object text.
    /// Brace matching is string-aware so braces inside quoted strings
    /// are ignored.
    private static func extractRouterData(from html: String) -> String? {
        guard let markerRange = html.range(of: "window._ROUTER_DATA") else {
            return nil
        }
        var cursor = markerRange.upperBound
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
}
