import Foundation

/// 一条学来的说法。
struct LearnedExpression: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case slang     // 网络用语、黑话
        case tic       // 口头禅
        case address   // 对方怎么称呼别人 / 希望被怎么称呼
        case rhythm    // 句式节奏（比如爱用省略号、爱反问）

        var displayName: String {
            switch self {
            case .slang: return "用语"
            case .tic: return "口头禅"
            case .address: return "称呼"
            case .rhythm: return "句式"
            }
        }
    }

    var text: String
    var kind: Kind
    var seen: Int = 1
    var firstSeen: Date = Date()
    var lastSeen: Date = Date()
    /// 她用了没有。学来的说法要真的用起来才算学会。
    var usedByPersona: Int = 0
}

/// 表达学习 —— MaiBot 最有趣的一个机制。
///
/// 人不只是「听内容」，还会**吸收对方的说法**：
/// 相处久了会开始用对方的口头禅，会被带着说同样的网络用语。
/// 这个机制让角色不是「一个固定人格在说话」，
/// 而是「一个会被你影响的人」。
///
/// 两条路：
///   - 离线：抓重复出现的短语、称呼模式（老X、X哥、X宝）
///   - 有模型：让她自己从最近的对话里挑「值得学的说法」
actor ExpressionLearner {
    static let shared = ExpressionLearner()

    private var book: [UUID: [LearnedExpression]] = [:]
    private let store = FileStore()
    /// 同一条说法出现几次才算「她在这么说」
    private let adoptionThreshold = 3
    /// 每个人最多留多少条
    private let capacity = 24

    init() {
        if let saved = store.load([UUID: [LearnedExpression]].self, from: "expressions.json") {
            book = saved
        }
    }

    // MARK: - 观察

    /// 每收到一条用户消息就喂一次。只做便宜的本地统计。
    func observe(userText: String, personaID: UUID) {
        let text = userText.trimmed
        guard text.count >= 2 else { return }

        var list = book[personaID] ?? []
        for candidate in Self.candidates(from: text) {
            if let index = list.firstIndex(where: { $0.text == candidate.text && $0.kind == candidate.kind }) {
                list[index].seen += 1
                list[index].lastSeen = Date()
            } else {
                list.append(candidate)
            }
        }
        // 丢掉只出现过一次、且很久没再出现的
        list = list.filter { $0.seen >= 2 || Date().timeIntervalSince($0.lastSeen) < 86_400 }
        list = Array(list.sorted { $0.seen > $1.seen }.prefix(capacity))
        book[personaID] = list
        persist()
    }

    func noteUsed(personaID: UUID, text: String) {
        var list = book[personaID] ?? []
        let lowered = text.lowercased()
        var changed = false
        for index in list.indices where lowered.contains(list[index].text.lowercased()) {
            list[index].usedByPersona += 1
            changed = true
        }
        if changed {
            book[personaID] = list
            persist()
        }
    }

    /// 已经「学进去」的说法 —— 出现够多次的那些。
    func adopted(for personaID: UUID, limit: Int = 8) -> [LearnedExpression] {
        (book[personaID] ?? [])
            .filter { $0.seen >= adoptionThreshold }
            .sorted { $0.seen * 2 + $0.usedByPersona > $1.seen * 2 + $1.usedByPersona }
            .prefix(limit)
            .map { $0 }
    }

    func all(for personaID: UUID) -> [LearnedExpression] {
        (book[personaID] ?? []).sorted { $0.seen > $1.seen }
    }

    func forget(personaID: UUID, text: String) {
        book[personaID]?.removeAll { $0.text == text }
        persist()
    }

    func clear(personaID: UUID) {
        book[personaID] = []
        persist()
    }

    /// 给 prompt 用的一段说明。
    func briefing(for persona: Persona) -> String? {
        let adopted = adopted(for: persona.id)
        guard !adopted.isEmpty else { return nil }
        let grouped = Dictionary(grouping: adopted, by: { $0.kind })
        var lines: [String] = ["你最近跟他相处，不知不觉学会了一些他的说法："]
        for (kind, items) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("- \(kind.displayName)：\(items.map { "「\($0.text)」" }.joined(separator: "、"))")
        }
        lines.append("用起来要自然 —— 偶尔带一句就够，每句都用会变成学舌。用了几次之后，它就真的成了你的话。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 模型精修

    /// 让模型从最近的对话里挑出值得学的说法。
    /// 离线抽取只能抓到重复和称呼；黑话、语气、句式这些要靠模型。
    func refine(persona: Persona, recentUserTexts: [String]) async {
        let sample = recentUserTexts.suffix(20).filter { $0.count >= 2 }
        guard sample.count >= 5 else { return }
        guard ProviderHub.shared.llm.id != "mock" else { return }

        let prompt = """
        下面是某人最近说的话。请挑出**值得被他的朋友学去的表达习惯**。

        \(sample.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        只挑真正有个人特色的：
        - slang：网络用语、黑话、圈内词
        - tic：口头禅、习惯性的语气词
        - address：他怎么称呼别人
        - rhythm：句式上的习惯（爱反问、爱用省略号、爱一句话拆成几条发）

        不要挑普通词汇，不要挑礼貌用语，不要编。没有就输出空数组。
        每条用原文里的说法，不要改写。

        只输出 JSON：
        [{"text":"说法","kind":"slang"}]
        """

        var output = ""
        do {
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .system, content: "你只输出 JSON。"),
                    LLMMessage(role: .user, content: prompt),
                ],
                temperature: 0.3,
                maxTokens: 400,
                model: ""
            )
            for try await delta in ProviderHub.shared.llm.stream(request) { output += delta }
        } catch {
            Log.memory.debug("expression refine failed: \(error.localizedDescription)")
            return
        }

        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        var list = book[persona.id] ?? []
        for item in array {
            guard let text = (item["text"] as? String)?.trimmed, !text.isBlank else { continue }
            let kind = LearnedExpression.Kind(rawValue: item["kind"] as? String ?? "slang") ?? .slang
            if let index = list.firstIndex(where: { $0.text == text }) {
                list[index].seen += 1
                list[index].lastSeen = Date()
            } else {
                list.append(LearnedExpression(text: text, kind: kind, seen: adoptionThreshold))
            }
        }
        book[persona.id] = Array(list.sorted { $0.seen > $1.seen }.prefix(capacity))
        persist()
    }

    // MARK: - 离线抽取

    /// 便宜的本地候选：称呼模式 + 反复出现的短句。
    static func candidates(from text: String) -> [LearnedExpression] {
        var result: [LearnedExpression] = []

        // 1. 称呼：老X / 小X / X哥 / X姐 / X宝 / X总
        let patterns: [(String, String)] = [
            ("[老小阿]([\\p{Han}]{1,2})", "老|小|阿 + 名"),
            ("([\\p{Han}]{1,2})(哥|姐|宝|总|叔|姨)", "名字 + 称谓"),
        ]
        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let token = String(text[matchRange])
                if token.count >= 2 && token.count <= 4 {
                    result.append(LearnedExpression(text: token, kind: .address))
                }
            }
        }

        // 2. 句首的语气词 / 短促表达（两到四字，独立成句的）
        for sentence in text.split(whereSeparator: { "。！？!?\n，,".contains($0) }) {
            let s = String(sentence).trimmed
            guard s.count >= 2 && s.count <= 5 else { continue }
            // 排除纯标点、纯数字、以及明显的普通词
            guard s.rangeOfCharacter(from: .letters) != nil || s.rangeOfCharacter(from: .punctuationCharacters) == nil else { continue }
            result.append(LearnedExpression(text: s, kind: .tic))
        }

        return result
    }

    private func persist() {
        store.save(book, to: "expressions.json")
    }
}
