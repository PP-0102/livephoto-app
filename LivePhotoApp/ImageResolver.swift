import Foundation

// MARK: - Model

/// One image found inside a Xiaohongshu note.
struct ImageItem: Identifiable {
    let id: String          // e.g. "1", "2", ... (index inside the note)
    let imageURL: URL       // still image (urlDefault)
    let width: Int
    let height: Int
}

// MARK: - Errors

enum ResolverError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case emptyResponse
    case stateNotFound
    case stateParseFailed
    case noteNotFound
    case noImages

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接无效，请粘贴完整的小红书笔记链接"
        case .httpError(let code): return "请求失败（HTTP \(code)），链接可能已过期，请重新复制链接再试"
        case .emptyResponse: return "没有取到笔记内容，请重新复制链接再试"
        case .stateNotFound: return "没有解析到笔记数据，链接可能已过期，请重新复制链接再试"
        case .stateParseFailed: return "笔记数据解析失败，请重新复制链接再试"
        case .noteNotFound: return "没有找到这篇笔记，请检查链接是否正确"
        case .noImages: return "这篇笔记里没有图片"
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

    /// Parse the note page HTML and return ALL images it contains.
    static func parseImages(from html: String) throws -> [ImageItem] {
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
        guard let imageList = note["imageList"] as? [[String: Any]] else {
            throw ResolverError.noImages
        }

        var items: [ImageItem] = []
        for (index, image) in imageList.enumerated() {
            guard let imageString = image["urlDefault"] as? String,
                  let imageURL = URL(string: httpsURL(imageString))
            else { continue }
            let width = (image["width"] as? NSNumber)?.intValue ?? 0
            let height = (image["height"] as? NSNumber)?.intValue ?? 0
            items.append(ImageItem(
                id: "\(index + 1)",
                imageURL: imageURL,
                width: width,
                height: height
            ))
        }
        guard !items.isEmpty else { throw ResolverError.noImages }
        return items
    }

    /// Convenience: fetch a link and return its images in one call.
    static func resolve(link: String) async throws -> [ImageItem] {
        let html = try await fetchNoteHTML(link: link)
        return try parseImages(from: html)
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
