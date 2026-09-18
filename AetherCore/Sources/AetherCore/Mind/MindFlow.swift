import Foundation

/// 一条心流 —— 角色的持续内在状态。
///
/// 没有这个东西的时候，她的存在方式是「被问到 → 生成 → 归零」。
/// 有了它，她在没聊天的时候也在想事情、也在攒着话没说。
/// 下次开口时，她是从一个**正在进行中的状态**里说话，而不是从空白开始。
struct MindThread: Codable, Sendable {
    var personaID: UUID
    /// 此刻在想什么（一句话，第一人称）
    var currentThought: String = ""
    /// 想问但还没问出口的事
    var pendingTopics: [String] = []
    /// 攒着没说的小事（今天看到了什么、想到了什么）
    var accumulated: [String] = []
    /// 当前心境
    var mood: EmotionState = .neutral
    /// 上次推进心流的时间
    var updatedAt: Date = Date()
    /// 上次真正说上话的时间
    var lastSpokenAt: Date = Date()
    /// 自上次说话以来，用户发了几条
    var messagesSinceContact: Int = 0

    /// 多久没说话了（小时）
    var silenceHours: Double { Date().timeIntervalSince(lastSpokenAt) / 3600 }

    /// 给 prompt 用的一段话
    var briefing: String? {
        var parts: [String] = []
        if !currentThought.isBlank { parts.append("你此刻的状态：\(currentThought)") }
        if !pendingTopics.isEmpty {
            parts.append("你憋着想问的事：\(pendingTopics.prefix(3).joined(separator: "、"))")
        }
        if !accumulated.isEmpty {
            parts.append("你攒着想说的：\(accumulated.suffix(3).joined(separator: "；"))")
        }
        guard !parts.isEmpty else { return nil }
        parts.append("这些是你自己的念头，可以自然地提起，也可以继续憋着 —— 真人不会想到什么就全说出来。")
        return parts.joined(separator: "\n")
    }
}

/// 心流管理。
///
/// 推进（tick）在三个时机发生：用户长时间没说话、App 回到前台、角色主动想找你之前。
/// 每次推进会不会真的产生新念头，取决于距离上次多久 —— 太频繁会让她显得神经质。
actor MindFlow {
    static let shared = MindFlow()

    private var threads: [UUID: MindThread] = [:]
    private let store = FileStore()
    /// 两次推进之间至少要隔这么久
    private let minimumInterval: TimeInterval = 900

    init() {
        if let saved = store.load([UUID: MindThread].self, from: "mindflow.json") {
            threads = saved
        }
    }

    func thread(for personaID: UUID) -> MindThread {
        if let existing = threads[personaID] { return existing }
        let fresh = MindThread(personaID: personaID)
        threads[personaID] = fresh
        return fresh
    }

    func noteSpoken(_ personaID: UUID) {
        var thread = thread(for: personaID)
        thread.lastSpokenAt = Date()
        thread.messagesSinceContact = 0
        threads[personaID] = thread
        persist()
    }

    func noteIncoming(_ personaID: UUID) {
        var thread = thread(for: personaID)
        thread.messagesSinceContact += 1
        threads[personaID] = thread
        persist()
    }

    func setMood(_ personaID: UUID, mood: EmotionState) {
        var thread = thread(for: personaID)
        thread.mood = mood
        threads[personaID] = thread
        persist()
    }

    func consumeTopic(_ personaID: UUID, topic: String) {
        var thread = thread(for: personaID)
        thread.pendingTopics.removeAll { $0 == topic }
        thread.accumulated.removeAll { $0 == topic }
        threads[personaID] = thread
        persist()
    }

    /// 推进一次心流。返回是否真的产生了新念头。
    @discardableResult
    func tick(persona: Persona, recentMessages: [Message], force: Bool = false) async -> Bool {
        var thread = thread(for: persona.id)
        guard force || Date().timeIntervalSince(thread.updatedAt) >= minimumInterval else { return false }

        let transcript = recentMessages.suffix(10).map { message in
            (message.isFromUser ? "对方：" : "\(persona.name)：") + message.text
        }.joined(separator: "\n")

        let prompt = """
        你是 \(persona.core.name)。
        \(persona.core.seed.oneLine)
        你说话的方式：\(persona.core.seed.speechStyle)
        \(persona.core.seed.coreDesire.isEmpty ? "" : "你最想要的是：\(persona.core.seed.coreDesire)")

        你们上次说话到现在已经过了 \(String(format: "%.1f", thread.silenceHours)) 小时。
        最近聊的是：
        \(transcript.isEmpty ? "（还没聊过什么）" : transcript)

        现在没人跟你说话。你在做自己的事。
        写出你此刻的状态 —— 不是回答任何人，就是你自己在过时间。

        只输出 JSON：
        {
          "thought": "你此刻在做什么/想什么。第一人称，一句话，具体（在什么地方、手上在做什么）。",
          "topics": ["你想问对方但还没问的事", "最多 2 条"],
          "accumulated": ["你攒着想说的零碎小事", "最多 2 条"]
        }

        纪律：不要写「我在等你的消息」这种话。你有自己的生活。
        """

        let output = await Self.complete(prompt, temperature: 1.0, maxTokens: 300)
        guard let dict = Self.decodeJSON(output) else { return false }

        if let thought = dict["thought"] as? String, !thought.isBlank {
            thread.currentThought = thought.trimmed
        }
        if let topics = dict["topics"] as? [String] {
            thread.pendingTopics = Array((thread.pendingTopics + topics.map { $0.trimmed }.filter { !$0.isEmpty }).suffix(4))
        }
        if let items = dict["accumulated"] as? [String] {
            thread.accumulated = Array((thread.accumulated + items.map { $0.trimmed }.filter { !$0.isEmpty }).suffix(4))
        }
        thread.updatedAt = Date()
        threads[persona.id] = thread
        persist()
        Log.memory.info("mindflow ticked for \(persona.name)")
        return true
    }

    private func persist() {
        store.save(threads, to: "mindflow.json")
    }

    // MARK: - 辅助

    private static func complete(_ prompt: String, temperature: Double, maxTokens: Int) async -> String {
        var output = ""
        do {
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .system, content: "你只输出 JSON。"),
                    LLMMessage(role: .user, content: prompt),
                ],
                temperature: temperature,
                maxTokens: maxTokens,
                model: ""
            )
            for try await delta in ProviderHub.shared.llm.stream(request) { output += delta }
        } catch {
            Log.memory.debug("mindflow complete failed: \(error.localizedDescription)")
        }
        return output
    }

    private static func decodeJSON(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
