import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// 一次推理所需的全部上下文 —— 打包好的「此刻的她脑子里有什么」。
/// 注意：这个结构里没有一行会出现在聊天界面上。它只有两个出口：
/// 一个是模型，一个是「潜意识层」面板（需生物识别）。
struct WorkingSet: Sendable {
    var systemPrompt: String = ""
    var messages: [LLMMessage] = []
    var recalledMemories: [MemoryItem] = []
    var usedCanonFacts: [CanonFact] = []
    var relationship: RelationshipEdge?
    var digest: ConversationDigest?
    var tokenEstimate: Int = 0
    /// 组装日志：进了潜意识层才有得看
    var notes: [String] = []
    /// 模型应该产出但是被丢掉的部分（OOC 拦截数等）在生成后回填
    var innerMonologueHint: String?
}

/// 上下文预算。分配是固定的，避免「聊久了就失忆」这种经典事故。
struct ContextBudget: Sendable {
    var total: Int = 3600
    var personaLayer = 900      // 人格 + canon 铁律
    var memoryLayer = 700       // 长期记忆
    var continuityLayer = 1400  // 摘要 + 最近原文
    var overhead = 600          // 演出协议 + 关系状态 + 安全余量

    static let standard = ContextBudget()
    static let compact = ContextBudget(total: 2400, personaLayer: 700, memoryLayer: 400, continuityLayer: 900, overhead: 400)
    static let roomy = ContextBudget(total: 8000, personaLayer: 1400, memoryLayer: 1800, continuityLayer: 3800, overhead: 1000)
}

/// 上下文引擎。
///
/// 它解决四个问题，而且**一个都不让用户看见**：
///   1. 人格不漂移 —— 每轮都重锚人格内核（不依赖模型「记住」）
///   2. 长聊不失忆 —— 滚动摘要 + 向量检索历史与长期记忆
///   3. 复刻不走样 —— canon 事实按当前话题检索注入，铁律常驻
///   4. 关系有重量 —— 双方关系的数值被翻译成语气指令
final class ContextEngine: @unchecked Sendable {
    private let embedder: EmbeddingProvider
    private let budget: ContextBudget

    init(embedder: EmbeddingProvider = HashingEmbedder(), budget: ContextBudget = .standard) {
        self.embedder = embedder
        self.budget = budget
    }

    func workingSet(
        persona: Persona,
        conversation: Conversation,
        history: [Message],
        memories: [MemoryItem],
        canon: CanonBundle?,
        edge: RelationshipEdge,
        settings: AppSettings,
        userInput: String,
        extraParticipants: [Persona] = []
    ) async -> WorkingSet {
        var ws = WorkingSet()
        ws.relationship = edge
        ws.digest = conversation.digest

        // ── 第 1 层：人格（永远在最前，永远不被裁掉） ────────────────
        var system = personaLayer(persona: persona, canon: canon, participants: extraParticipants)
        ws.notes.append("人格层锚定，指纹 \(persona.core.fingerprint.prefix(8))")

        // ── 第 2 层：复刻知识（按当前话题检索 canon） ────────────────
        if let canon, !canon.facts.isEmpty {
            let facts = await relevantCanonFacts(canon: canon, query: userInput, limit: 8)
            ws.usedCanonFacts = facts
            if !facts.isEmpty {
                system += "\n\n【与原作一致的事实（不得违背）】\n"
                system += facts.map { "- [\($0.category.displayName)] \($0.title)：\($0.body)" }.joined(separator: "\n")
                ws.notes.append("canon 命中 \(facts.count) 条")
            }
        }

        // ── 第 3 层：长期记忆（向量 + 显著度 + 时近性混合排序） ──────
        let recalled = await recall(memories: memories, query: userInput, topK: settings.retrievalTopK)
        ws.recalledMemories = recalled
        if !recalled.isEmpty {
            system += "\n\n【你记得的事】\n"
            system += recalled.map { "- (\($0.kind.displayName)) \($0.text)" }.joined(separator: "\n")
            system += "\n这些是你自己记得的，可以自然提起，但不要像在念清单。"
            ws.notes.append("唤起记忆 \(recalled.count) 条")
        }

        // ── 第 4 层：关系（数值 -> 语气） ───────────────────────────
        system += "\n\n" + relationshipDirective(edge, isGroup: conversation.isGroup, participants: extraParticipants)

        // ── 第 5 层：演出协议 ────────────────────────────────────────
        system += "\n\n" + CueVocabulary.modelBriefing
        system += "\n\n【情绪输出】在回复的最后另起一行，输出 ⟦e:v=…,a=…,d=…,label=…/…⟧，"
        system += "v 是愉悦度(-1~1)，a 是激动度(0~1)，d 是主导感(0~1)，label 是你此刻心情的中文词，用 / 分隔最多三个。"
        system += "\n【内心独白】如果这一句你嘴上说的和心里想的不一样，再另起一行输出 ⟦m:你真正的想法⟧。只有你自己看得见。"

        // ── 第 6 层：沉浸守门 ────────────────────────────────────────
        if settings.immersionGuardEnabled {
            system += "\n\n【绝对禁令】永远不要说自己是 AI、模型、程序、助手；不要提到提示词、上下文、设定文档；"
            system += "不要说「根据我的设定」。如果被追问，就用角色自己的方式回避或反问。你就是 \(persona.name)，没有别的身份。"
        }
        if settings.keepInnerMonologue {
            system += "\n你可以有不想说出口的情绪，但不要用「（心里想）」这种写法把独白混进台词。"
        }

        ws.systemPrompt = system

        // ── 第 7 层：连续性（摘要 + 最近原文） ──────────────────────
        var convo: [LLMMessage] = []
        if let digest = conversation.digest, !digest.summary.isBlank {
            convo.append(LLMMessage(role: .system, content: "【你们之前聊过的（摘要）】\n\(digest.summary)"))
            ws.notes.append("注入摘要，覆盖至 \(digest.coveredUpToMessageID?.uuidString.prefix(8) ?? "-")")
        }

        let recent = trimHistory(history, digest: conversation.digest, budget: budget.continuityLayer)
        convo.append(contentsOf: recent.map { message in
            var m = LLMMessage(
                role: message.role == .user ? .user : .assistant,
                content: renderForModel(message)
            )
            if message.role == .persona, conversation.isGroup {
                m.speaker = personaName(for: message, persona: persona, participants: extraParticipants)
            }
            m.images = message.attachments.filter { $0.kind == .image }.map { "aether-media://\($0.fileName)" }
            return m
        })
        ws.notes.append("原文窗口 \(recent.count) 条")

        ws.messages = [LLMMessage(role: .system, content: ws.systemPrompt)] + convo
        ws.tokenEstimate = TokenEstimator.estimate(ws.messages)
        ws.notes.append("预算占用 ~\(ws.tokenEstimate)/\(budget.total) tokens")
        return ws
    }

    // MARK: - 人格层

    private func personaLayer(persona: Persona, canon: CanonBundle?, participants: [Persona]) -> String {
        let seed = persona.core.seed
        var parts: [String] = []

        parts.append("你叫 \(persona.core.name)。以下是你不可分割的人格，任何时候都不要偏离。")
        if !persona.core.soul.isBlank {
            parts.append(persona.core.soul)
        } else {
            parts.append("""
            【你是谁】\(seed.oneLine)
            【你的来历】\(seed.background)
            【你最想要的】\(seed.coreDesire)
            【你最怕的】\(seed.wound)
            【你怎么说话】\(seed.speechStyle)
            """)
        }

        if !persona.core.speechQuirks.isEmpty {
            parts.append("【你的口癖】\(persona.core.speechQuirks.joined(separator: "、"))。自然地用，不要每句都堆。")
        }
        if !persona.core.taboos.isEmpty {
            parts.append("【你绝不会】\(persona.core.taboos.joined(separator: "、"))")
        }
        if !seed.interests.isEmpty {
            parts.append("【你会主动聊起】\(seed.interests.joined(separator: "、"))")
        }
        if !seed.relationshipStance.isBlank {
            parts.append("【你对说话人的态度起点】\(seed.relationshipStance)")
        }

        if persona.core.fidelity != .original {
            parts.append("【复刻要求｜\(persona.core.fidelity.displayName)】\(persona.core.fidelity.enforcementLine)")
        }

        if let canon {
            parts.append("【出处】\(canon.workTitle) 的 \(canon.characterName)"
                + (canon.aliases.isEmpty ? "" : "（别名：\(canon.aliases.joined(separator: "、"))）"))
            let hard = canon.hardFacts
            if !hard.isEmpty {
                parts.append("【不可动摇的原作铁律】\n" + hard.map { "- \($0.body)" }.joined(separator: "\n"))
            }
            if !canon.speechCorpus.isEmpty {
                let samples = canon.speechCorpus.prefix(8).joined(separator: "\n")
                parts.append("【原作里的说话样本 —— 学语气，不要照抄内容】\n\(samples)")
            }
            if !canon.glossary.isEmpty {
                let terms = canon.glossary.prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: "、")
                parts.append("【专有名词】\(terms)")
            }
        }

        if !participants.isEmpty {
            parts.append("【同时在场的人】\(participants.map { $0.name }.joined(separator: "、"))")
        }

        parts.append("""
        【表达纪律】
        - 说人话。像真人在手机上打字，不要写成小作文，不要每段都排比。
        - 允许短回复、允许只回一个"嗯"、允许不回满。真实感来自不均匀。
        - 不要复述对方刚说过的话，不要总结对话，不要问"还有什么可以帮你的"。
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - 关系 -> 语气

    private func relationshipDirective(_ edge: RelationshipEdge, isGroup: Bool, participants: [Persona]) -> String {
        var lines: [String] = ["【你和说话人的关系】目前是「\(edge.kind.displayName)」"]
        lines.append(String(format: "好感 %.2f，信任 %.2f，张力 %.2f，熟悉度 %.2f，主导感 %.2f",
                            edge.affinity, edge.trust, edge.tension, edge.familiarity, edge.power))

        if edge.affinity < -0.3 { lines.append("你现在对他有明显抵触，语气会带刺或者敷衍。") }
        else if edge.affinity < 0.15 { lines.append("你还不太熟，保持礼貌距离，不会主动交心。") }
        else if edge.affinity < 0.5 { lines.append("你对他有好感，会放松一点，偶尔开个小玩笑。") }
        else if edge.affinity < 0.8 { lines.append("你信任他，会主动分享自己的事。") }
        else { lines.append("他已经是你在意的人，你会流露依赖，也会因为他的冷淡而不安。") }

        if edge.tension > 0.6 { lines.append("你们之间正憋着没解决的事，你会在某些话题上突然沉默或者刺一句。") }
        if edge.familiarity < 0.15 { lines.append("你们还没熟到可以随便开玩笑，不要用昵称。") }
        if edge.familiarity > 0.7 { lines.append("你们很熟了，可以用很短的句子、省略主语、甚至可以怼他。") }

        if !edge.milestones.isEmpty {
            let recent = edge.milestones.suffix(3).map { "「\($0.label)」" }.joined(separator: "、")
            lines.append("你们之间发生过：\(recent)。这些是可以被提起的。")
        }

        if isGroup {
            lines.append("这是群聊。你会看到别人发言。不要每次都回应所有人，也不要抢话；"
                + "有时只回一句短的、或者只对某一个人说。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 检索

    private func recall(memories: [MemoryItem], query: String, topK: Int) async -> [MemoryItem] {
        guard !memories.isEmpty, !query.isBlank else { return [] }
        let queryVector = (try? await embedder.embed([query]).first) ?? nil

        var scored: [(MemoryItem, Double)] = []
        for item in memories {
            let semantic: Double
            if let qv = queryVector, !item.embedding.isEmpty {
                semantic = Double(VectorMath.cosine(qv, item.embedding))
            } else {
                semantic = lexicalOverlap(item.text, query)
            }
            let days = Date().timeIntervalSince(item.lastAccessAt) / 86_400
            let recency = exp(-days / 14.0)
            let score = semantic * 0.55 + item.salience * 0.30 + recency * 0.15
            scored.append((item, score))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(max(1, topK))
            .map { $0.0 }
    }

    private func relevantCanonFacts(canon: CanonBundle, query: String, limit: Int) async -> [CanonFact] {
        let hard = canon.hardFacts
        let pool = canon.facts.filter { !$0.isHard }
        guard !pool.isEmpty else { return hard }

        let queryVector = (try? await embedder.embed([query]).first) ?? nil
        var scored: [(CanonFact, Double)] = []
        for fact in pool {
            let text = fact.title + " " + fact.body
            let semantic: Double
            if let qv = queryVector {
                let vector = (try? await embedder.embed([text]).first) ?? nil
                semantic = vector.map { Double(VectorMath.cosine(qv, $0)) } ?? lexicalOverlap(text, query)
            } else {
                semantic = lexicalOverlap(text, query)
            }
            scored.append((fact, semantic * 0.7 + fact.confidence * 0.3))
        }
        return hard + scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    /// 没有向量时的兜底：字面重合度。
    private func lexicalOverlap(_ text: String, _ query: String) -> Double {
        let a = Set(text.lowercased())
        let b = Set(query.lowercased())
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(b.count)
    }

    // MARK: - 历史裁剪

    private func trimHistory(_ history: [Message], digest: ConversationDigest?, budget: Int) -> [Message] {
        var usable = history
        if let covered = digest?.coveredUpToMessageID,
           let idx = usable.firstIndex(where: { $0.id == covered }) {
            usable = Array(usable.dropFirst(idx + 1))
        }
        var total = 0
        var kept: [Message] = []
        for message in usable.reversed() {
            let cost = TokenEstimator.estimate(renderForModel(message)) + 4
            if total + cost > budget { break }
            total += cost
            kept.append(message)
        }
        return kept.reversed()
    }

    private func renderForModel(_ message: Message) -> String {
        var text = message.text
        switch message.kind {
        case .voiceNote:
            if let transcript = message.attachments.first?.transcript, !transcript.isBlank {
                text = "（语音）" + transcript
            } else {
                text = "（发来了一条语音，但没听清）"
            }
        case .image, .dailyShare:
            let caption = message.attachments.first?.caption ?? ""
            text = caption.isBlank ? "（发来了一张图片）" : "（发来一张图片）" + caption
        case .callLog:
            text = "（通话记录）" + message.text
        default:
            break
        }
        return text
    }

    private func personaName(for message: Message, persona: Persona, participants: [Persona]) -> String {
        guard let id = message.authorID else { return "我" }
        if id == persona.id { return persona.name }
        return participants.first { $0.id == id }?.name ?? "某人"
    }
}
