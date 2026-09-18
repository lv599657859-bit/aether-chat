import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 一条抓到的原始资料。
struct FetchedDocument: Sendable {
    var source: CanonSource
    /// 页面正文（已去 wiki 标记）
    var text: String
    var length: Int { text.count }
}

/// 资料源。默认实现覆盖 MediaWiki 系：维基百科 / Fandom / 萌娘百科。
protocol CanonSourceFetcher: Sendable {
    var kind: CanonSource.Kind { get }
    var displayName: String { get }
    func search(_ query: String, limit: Int) async throws -> [String]
    func fetch(title: String) async throws -> FetchedDocument?
}

/// MediaWiki API 客户端。
///
/// 为什么选它：维基百科、Fandom、萌娘百科三家都是 MediaWiki，
/// 同一套 query/prop=extracts/explaintext 接口就能同时打通 ——
/// 这覆盖了绝大多数游戏与动画角色的公开设定资料。
final class MediaWikiFetcher: CanonSourceFetcher, @unchecked Sendable {
    let kind: CanonSource.Kind
    let displayName: String

    private let endpoint: URL
    private let session: URLSession

    init(kind: CanonSource.Kind, displayName: String, endpoint: String, session: URLSession = .shared) {
        self.kind = kind
        self.displayName = displayName
        self.endpoint = URL(string: endpoint)!
        self.session = session
    }

    static func wikipedia(language: String = "zh") -> MediaWikiFetcher {
        MediaWikiFetcher(
            kind: .wiki, displayName: "维基百科",
            endpoint: "https://\(language).wikipedia.org/w/api.php"
        )
    }

    static func moegirl() -> MediaWikiFetcher {
        MediaWikiFetcher(kind: .moegirl, displayName: "萌娘百科", endpoint: "https://zh.moegirl.org.cn/api.php")
    }

    static func fandom(subdomain: String) -> MediaWikiFetcher {
        MediaWikiFetcher(
            kind: .fandom, displayName: "Fandom " + subdomain,
            endpoint: "https://\(subdomain).fandom.com/api.php"
        )
    }

    func search(_ query: String, limit: Int = 5) async throws -> [String] {
        let url = try buildURL([
            "action": "query", "list": "search", "srsearch": query,
            "srlimit": String(limit), "format": "json", "utf8": "1",
        ])
        let json = try await getJSON(url)
        guard let body = json["query"] as? [String: Any],
              let results = body["search"] as? [[String: Any]] else { return [] }
        return results.compactMap { $0["title"] as? String }
    }

    func fetch(title: String) async throws -> FetchedDocument? {
        let url = try buildURL([
            "action": "query", "prop": "extracts", "explaintext": "1",
            "redirects": "1", "titles": title, "format": "json", "utf8": "1",
        ])
        let json = try await getJSON(url)
        guard let body = json["query"] as? [String: Any],
              let pages = body["pages"] as? [String: Any] else { return nil }

        for (_, value) in pages {
            guard let page = value as? [String: Any],
                  let extract = page["extract"] as? String,
                  extract.count > 200 else { continue }
            let realTitle = page["title"] as? String ?? title
            let source = CanonSource(kind: kind, title: realTitle, url: pageURL(title: realTitle))
            return FetchedDocument(source: source, text: Self.stripWikiMarkup(extract))
        }
        return nil
    }

    private func pageURL(title: String) -> String {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let path = (components?.path ?? "/w/api.php").replacingOccurrences(of: "api.php", with: "wiki/")
        components?.path = path
        components?.query = nil
        let base = components?.url?.absoluteString ?? ""
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return base + encoded
    }

    private func buildURL(_ items: [String: String]) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw LLMError.empty }
        return url
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("AetherChat/0.1 (character canon research)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.empty
        }
        return json
    }

    /// 去掉 wiki 标记，留下可读正文。
    static func stripWikiMarkup(_ raw: String) -> String {
        var text = raw
        let patterns = [
            "\\[\\[[^\\]|]*\\|([^\\]]*)\\]\\]",
            "\\[\\[([^\\]]*)\\]\\]",
            "\\{\\{[^{}]*\\}\\}",
            "'''|''",
            "<ref[^>]*>.*?</ref>",
            "<[^>]+>",
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmed
    }
}

/// 用户手填或粘贴的资料。对冷门作品，这是最靠谱的一条路。
struct ManualFetcher: CanonSourceFetcher {
    let kind: CanonSource.Kind = .manual
    let displayName = "手动录入"
    let title: String
    let body: String

    func search(_ query: String, limit: Int) async throws -> [String] { [title] }

    func fetch(title: String) async throws -> FetchedDocument? {
        guard !body.isBlank else { return nil }
        return FetchedDocument(
            source: CanonSource(kind: .manual, title: title, url: "local://manual"),
            text: body
        )
    }
}

/// 把长文切成适合喂给模型的片段。按段落聚拢，不切断语义。
enum DocumentChunker {
    static func chunks(_ text: String, targetSize: Int = 1800) -> [String] {
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.count + paragraph.count > targetSize, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += paragraph + "\n"
        }
        if !current.trimmed.isEmpty { result.append(current) }
        return result
    }
}
