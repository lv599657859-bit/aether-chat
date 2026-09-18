import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SearchHit: Sendable, Hashable {
    var title: String
    var url: String
    var snippet: String
}

/// 联网检索。
///
/// 刻意做成**不需要任何密钥**：agent 要是离了 API Key 就连不上网，
/// 那「自己去查资料」就是一句空话。
/// 两条路：DuckDuckGo 的 HTML 端点（宽），MediaWiki 的搜索 API（准）。
enum WebSearch {
    /// 综合搜索：先 DDG，结果太少再补 MediaWiki。
    static func search(_ query: String, limit: Int = 6) async -> [SearchHit] {
        var hits = await duckduckgo(query, limit: limit)
        if hits.count < 3 {
            let wiki = await mediaWiki(query, limit: limit, language: "zh")
            for hit in wiki where !hits.contains(where: { $0.url == hit.url }) {
                hits.append(hit)
            }
        }
        var seen = Set<String>()
        return hits.filter { hit in
            if seen.contains(hit.url) { return false }
            seen.insert(hit.url)
            return true
        }.prefix(limit).map { $0 }
    }

    // MARK: - DuckDuckGo

    private static func duckduckgo(_ query: String, limit: Int) async -> [SearchHit] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let html = await fetchString(request) else { return [] }

        var hits: [SearchHit] = []
        // 结果块：<a rel="nofollow" class="result__a" href="...">标题</a> ... <a class="result__snippet">摘要</a>
        let pattern = "<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>(.*?)(?=<a[^>]*class=\"[^\"]*result__a|</body>)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range).prefix(limit) {
            guard match.numberOfRanges >= 4,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let bodyRange = Range(match.range(at: 3), in: html) else { continue }
            let raw = String(html[urlRange])
            let decoded = decodeDuckDuckGoURL(raw)
            guard decoded.hasPrefix("http") else { continue }
            let title = stripHTML(String(html[titleRange]))
            let snippet = stripHTML(String(html[bodyRange]))
            guard !title.isBlank else { continue }
            hits.append(SearchHit(title: title, url: decoded, snippet: String(snippet.prefix(220))))
        }
        return hits
    }

    /// DDG 的链接是 //duckduckgo.com/l/?uddg=<编码后的真实地址>
    private static func decodeDuckDuckGoURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return raw }
        return target
    }

    // MARK: - MediaWiki

    static func mediaWiki(_ query: String, limit: Int, language: String) async -> [SearchHit] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(language).wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&srlimit=\(limit)&format=json") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("AetherChat/0.3 (agent research)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let data = await fetchData(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["query"] as? [String: Any],
              let results = body["search"] as? [[String: Any]] else { return [] }

        return results.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            let snippet = stripHTML(item["snippet"] as? String ?? "")
            let page = "https://\(language).wikipedia.org/wiki/"
                + (title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)
            return SearchHit(title: title, url: page, snippet: snippet)
        }
    }

    // MARK: - 抓正文

    /// 抓一个网页并转成可读文本。
    static func fetchText(_ urlString: String, limit: Int = 4000) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        guard let html = await fetchString(request) else { return nil }
        let text = stripHTML(html)
        guard !text.isBlank else { return nil }
        return String(text.prefix(limit))
    }

    // MARK: - 基础

    private static func fetchData(_ request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.aetherData(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            Log.llm.debug("web fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchString(_ request: URLRequest) async -> String? {
        guard let data = await fetchData(request) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// 去标签、去脚本、压空白。够用，不追求完整 HTML 解析。
    static func stripHTML(_ html: String) -> String {
        var text = html
        let patterns = [
            "<script[^>]*>.*?</script>",
            "<style[^>]*>.*?</style>",
            "<noscript[^>]*>.*?</noscript>",
            "<!--.*?-->",
            "<[^>]+>",
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&mdash;": "—", "&hellip;": "…",
        ]
        for (key, value) in entities { text = text.replacingOccurrences(of: key, with: value) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmed
    }
}
