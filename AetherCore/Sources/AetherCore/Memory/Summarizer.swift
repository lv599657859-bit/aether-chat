import Foundation

/// 滚动摘要器。
///
/// 触发条件：会话原文超过阈值 —— 用户永远不会知道这件事发生过。
/// 摘要本身也只活在隐藏层：它进 prompt，不进界面。
final class Summarizer: @unchecked Sendable {
    private let provider: LLMProvider

    init(provider: LLMProvider) {
        self.provider = provider
    }

    struct Result: Sendable {
        var digest: ConversationDigest
        var tokensSaved: Int
    }

    /// 把「摘要覆盖点之后、最近 N 条之前」的那一段压成摘要。
    /// - Parameter keepRecent: 保留原文的条数，这部分不进摘要（保留细节）
    func summarize(
        conversation: Conversation,
        history: [Message],
        personaName: String,
        keepRecent: Int = 16
    ) async -> Result? {
        let digest = conversation.digest
        var slice = history
        if let covered = digest?.coveredUpToMessageID,
           let idx = slice.firstIndex(where: { $0.id == covered }) {
            slice = Array(slice.dropFirst(idx + 1))
        }
        guard slice.count > keepRecent else { return nil }

        let toCompress = Array(slice.dropLast(keepRecent))
        guard let lastCovered = toCompress.last else { return nil }

        let transcript = toCompress.map { message -> String in
            let who = message.isFromUser ? "我" : (message.authorID == nil ? personaName : personaName)
            return "\(who)：\(message.text)"
        }.joined(separator: "\n")

        let previous = digest?.summary ?? "（还没有摘要）"
        let prompt = """
        你在维护一段长期对话的记忆。把下面的对话压缩成一段摘要，供以后使用。

        要求：
        1. 保留：发生过的事、说到做到的事、对方透露的私人信息、情绪转折点、未解决的悬念。
        2. 丢弃：寒暄、重复、无信息的语气词。
        3. 用第三人称写，不要写成对话记录。
        4. 标注「未完结的线」：还没聊完的话题。
        5. 长度控制在 200 字以内。用中文。

        已有摘要：
        \(previous)

        新增对话：
        \(transcript)

        按以下格式输出，不要有别的内容：
        [摘要]……
        [未完结]用 / 分隔的话题列表
        [情绪线]一句话描述这段关系的情绪走向
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: "你是一个冷静的记忆压缩器，只输出要求格式的内容。"),
                LLMMessage(role: .user, content: prompt),
            ],
            temperature: 0.3,
            maxTokens: 500
        )

        var output = ""
        do {
            for try await delta in provider.stream(request) { output += delta }
        } catch {
            Log.memory.error("summarize failed: \(error.localizedDescription)")
            return nil
        }

        let summary = Self.section(output, tag: "摘要") ?? output
        let threads = (Self.section(output, tag: "未完结") ?? "")
            .split(separator: "/").map { String($0).trimmed }.filter { !$0.isEmpty }
        let arc = Self.section(output, tag: "情绪线") ?? ""

        let result = ConversationDigest(
            conversationID: conversation.id,
            summary: summary,
            coveredUpToMessageID: lastCovered.id,
            openThreads: threads,
            emotionalArc: arc,
            tokensSaved: TokenEstimator.estimate(transcript) - TokenEstimator.estimate(summary)
        )
        Log.memory.info("summarized \(toCompress.count) messages, saved ~\(result.tokensSaved) tokens")
        return Result(digest: result, tokensSaved: result.tokensSaved)
    }

    private static func section(_ text: String, tag: String) -> String? {
        guard let range = text.range(of: "[\(tag)]") else { return nil }
        let rest = text[range.upperBound...]
        let end = rest.firstIndex(of: "[") ?? rest.endIndex
        let value = String(rest[..<end]).trimmed
        return value.isEmpty ? nil : value
    }
}
