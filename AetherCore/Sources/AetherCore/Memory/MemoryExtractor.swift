import Foundation

/// 记忆抽取器。
///
/// 每轮对话结束后在后台跑一次 —— 用户看不到「正在整理记忆」这种提示，
/// 但下一次聊天时角色会突然记得「你上周说你不吃香菜」。
/// 这就是「自行解决上下文问题」的手感来源。
final class MemoryExtractor: @unchecked Sendable {
    private let provider: LLMProvider
    private let embedder: EmbeddingProvider

    init(provider: LLMProvider, embedder: EmbeddingProvider = HashingEmbedder()) {
        self.provider = provider
        self.embedder = embedder
    }

    struct Extracted: Sendable {
        var kind: MemoryItem.Kind
        var text: String
        var salience: Double
        var annotation: String?
    }

    func extract(
        userText: String,
        personaText: String,
        streamID: UUID,
        sourceMessageID: UUID?
    ) async -> [MemoryItem] {
        guard !userText.isBlank else { return [] }

        let prompt = """
        从下面这段对话里，抽取值得长期记住的信息。

        只抽这六类：
        fact（关于对方的客观事实）、preference（喜好厌恶）、event（一起发生的事）、
        feeling（你自己的情绪记忆）、promise（约定）、secret（对方透露的私密事）

        规则：
        - 只抽「以后还用得上」的。寒暄、客套、天气，一律不要。
        - 每条一句话，主语明确。用中文。
        - salience 0-1，越重要越高。约定和私密事给 0.8 以上。
        - annotation 是你对这件事的主观感受，一句话，可以带情绪。没有就留空。
        - 最多 4 条。一条都没有就输出空数组。

        对话：
        我：\(userText)
        你：\(personaText)

        只输出 JSON 数组，不要解释：
        [{"kind":"fact","text":"...","salience":0.6,"annotation":"..."}]
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: "你是一个精确的记忆抽取器，只输出 JSON。"),
                LLMMessage(role: .user, content: prompt),
            ],
            temperature: 0.2,
            maxTokens: 500
        )

        var output = ""
        do {
            for try await delta in provider.stream(request) { output += delta }
        } catch {
            Log.memory.error("extract failed: \(error.localizedDescription)")
            return offlineExtract(userText: userText, streamID: streamID, sourceMessageID: sourceMessageID)
        }

        let items = Self.decode(output, streamID: streamID, sourceMessageID: sourceMessageID)
        if items.isEmpty {
            return offlineExtract(userText: userText, streamID: streamID, sourceMessageID: sourceMessageID)
        }
        return await attachEmbeddings(items)
    }

    private static func decode(_ raw: String, streamID: UUID, sourceMessageID: UUID?) -> [MemoryItem] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let text = dict["text"] as? String, !text.isBlank else { return nil }
            let kind = MemoryItem.Kind(rawValue: dict["kind"] as? String ?? "fact") ?? .fact
            let annotation = (dict["annotation"] as? String)?.trimmed
            return MemoryItem(
                streamID: streamID,
                kind: kind,
                text: text.trimmed,
                salience: (dict["salience"] as? Double ?? 0.5).clamped(0.05, 1),
                sourceMessageID: sourceMessageID,
                annotation: (annotation?.isEmpty ?? true) ? nil : annotation
            )
        }
    }

    /// 没有模型时的兜底：用简单规则抓「我叫…」「我不吃…」这类句子。
    /// 笨，但保证离线也能长记性。
    ///
    /// 两个踩过的坑，写在这里免得再犯：
    ///   1. 一句话可能同时命中多类（「我叫小林，我不吃香菜」= 事实 + 偏好），
    ///      所以命中之后不能 break。
    ///   2. 记忆片段从**命中处**截到句尾，而不是整句照抄 ——
    ///      否则两条记忆里会出现同一串字，检索时互相打架。
    func offlineExtract(userText: String, streamID: UUID, sourceMessageID: UUID?) -> [MemoryItem] {
        let patterns: [(String, MemoryItem.Kind, Double)] = [
            ("我叫", .fact, 0.9), ("我姓", .fact, 0.85), ("我是", .fact, 0.7),
            ("我住在", .fact, 0.7), ("我住", .fact, 0.7),
            ("我今年", .fact, 0.6), ("我的生日", .fact, 0.85),
            ("我喜欢", .preference, 0.6), ("我最喜欢", .preference, 0.7),
            ("我不喜欢", .preference, 0.65), ("我讨厌", .preference, 0.65),
            ("我不吃", .preference, 0.75), ("我不喝", .preference, 0.7),
            ("我不能吃", .preference, 0.75), ("我对.*过敏", .fact, 0.9),
            ("我答应", .promise, 0.8), ("约好", .promise, 0.8), ("说好", .promise, 0.8),
            ("其实我", .secret, 0.8), ("别告诉", .secret, 0.9),
        ]

        var items: [MemoryItem] = []
        for sentence in userText.split(whereSeparator: { "。！？!?\n".contains($0) }) {
            let s = String(sentence).trimmed
            guard s.count >= 4, s.count <= 60 else { continue }
            for (pattern, kind, salience) in patterns {
                let range = pattern.contains(".*")
                    ? s.range(of: pattern, options: .regularExpression)
                    : s.range(of: pattern)
                guard let range else { continue }
                let fragment = String(s[range.lowerBound...]).trimmed
                guard fragment.count >= 3 else { continue }
                guard !items.contains(where: { $0.kind == kind && $0.text == fragment }) else { continue }
                items.append(MemoryItem(
                    streamID: streamID,
                    kind: kind,
                    text: fragment,
                    salience: salience,
                    sourceMessageID: sourceMessageID
                ))
            }
            if items.count >= 4 { break }
        }
        return Array(items.prefix(4))
    }

    private func attachEmbeddings(_ items: [MemoryItem]) async -> [MemoryItem] {
        guard !items.isEmpty else { return [] }
        let vectors = (try? await embedder.embed(items.map { $0.text })) ?? []
        guard vectors.count == items.count else { return items }
        return zip(items, vectors).map { item, vector in
            var copy = item
            copy.embedding = vector
            return copy
        }
    }
}
