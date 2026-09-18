import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 任何 OpenAI 兼容接口（OpenAI / DeepSeek / 自建 vLLM / Ollama 的兼容层）。
/// 换服务商只需要改 baseURL 和 Key，其他代码一行不动。
final class OpenAICompatibleProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName: String

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(id: String = "openai",
         displayName: String = "OpenAI 兼容接口",
         baseURL: String,
         apiKey: String,
         session: URLSession = .shared) {
        self.id = id
        self.displayName = displayName
        self.baseURL = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.session = session
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
                    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.timeoutInterval = 120
                    urlRequest.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.body(from: request), options: []
                    )

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw LLMError.empty }
                    guard (200..<300).contains(http.statusCode) else {
                        var collected = ""
                        for try await line in bytes.lines { collected += line }
                        throw LLMError.badStatus(http.statusCode, collected)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmed
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func body(from request: LLMRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        for message in request.messages {
            if message.images.isEmpty {
                messages.append(["role": message.role.rawValue, "content": message.content])
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": message.content]]
                for url in message.images {
                    parts.append(["type": "image_url", "image_url": ["url": url]])
                }
                messages.append(["role": message.role.rawValue, "content": parts])
            }
        }
        var body: [String: Any] = [
            "messages": messages,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens,
            "stream": true,
        ]
        if !request.model.isEmpty { body["model"] = request.model }
        if !request.stop.isEmpty { body["stop"] = request.stop }
        return body
    }
}

/// 图像生成：角色发来的「日常照片」。
final class OpenAIImageProvider: ImageProvider, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.model = model
    }

    func generate(prompt: String, aspect: ImageAspect) async throws -> Data {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent("images/generations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "size": aspect.rawValue,
            "n": 1,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first else { throw LLMError.empty }

        if let b64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: b64) {
            return decoded
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            let (imageData, _) = try await URLSession.shared.data(from: url)
            return imageData
        }
        throw LLMError.empty
    }
}

/// 向量化：长期记忆检索。默认走 OpenAI embeddings。
final class OpenAIEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.model = model
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw LLMError.empty }
        return items.compactMap { item in
            (item["embedding"] as? [Double])?.map { Float($0) }
        }
    }
}
