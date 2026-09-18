import AetherCore
import Foundation

/// 自主性调度。
///
/// 用户的两个要求靠它实现：
///   1. 「可以让他发图片发日常」—— 她会自己发消息、发照片过来。
///   2. 「他们甚至有可能会自己发展出关系」—— 你不看的时候，他们之间也在发生事。
///
/// 关键取舍：角色之间的私聊**不直接显示在聊天列表里**（那会像在看后台日志，很出戏）。
/// 它只做两件事：改变关系数值，以及让对方下次聊天时自然提起。
/// 全过程记进「潜意识层」，想查的人查得到。
final class AutonomyScheduler: @unchecked Sendable {
    private let store: WorldStore
    private let director = GroupDirector()

    init(store: WorldStore = .shared) {
        self.store = store
    }

    /// 一次心跳。App 回前台、后台刷新、或用户长时间没动作时调用。
    func tick() async {
        let settings = await store.currentSettings()
        guard settings.autonomyEnabled else { return }

        await reconcileInterCharacterEdges()

        if settings.interCharacterChatterEnabled {
            await runInterCharacterScenes(limit: 1, settings: settings)
        }

        let personas = await store.allPersonas()
        for persona in personas {
            await considerOutreach(persona: persona, settings: settings)
        }
    }

    // MARK: - 主动找你

    private func considerOutreach(persona: Persona, settings: AppSettings) async {
        guard !persona.presentation.isMuted else { return }
        guard let conversation = await store.directConversation(with: persona.id) else { return }

        let hour = Calendar.current.component(.hour, from: Date())
        let window = persona.presentation.sleepWindow
        if window.count == 2, window[0] <= window[1], (window[0]..<window[1]).contains(hour) {
            return   // 她在睡觉，不打扰
        }

        let history = await store.messages(in: conversation.id)
        let lastFromPersona = history.last { $0.role == .persona }
        let silenceHours = Date().timeIntervalSince(lastFromPersona?.createdAt ?? .distantPast) / 3600

        let edge = await store.edge(from: persona.id, to: nil)
        var probability = persona.presentation.proactiveLevel * 0.25
        probability += edge.affinity > 0.5 ? 0.15 : 0
        probability += min(0.25, silenceHours / 72 * 0.25)
        guard Double.random(in: 0...1) < probability else { return }

        let kind = pickOutreachKind(hour: hour, edge: edge, settings: settings)
        await deliverOutreach(persona: persona, conversation: conversation, kind: kind)
    }

    private enum OutreachKind: Sendable {
        case greeting(String)
        case recall(String)         // "突然想起你说的"
        case dailyPhoto(String)     // 日常照片
        case voiceNote(String)      // 语音
        case silence()
    }

    private func pickOutreachKind(hour: Int, edge: RelationshipEdge, settings: AppSettings) -> OutreachKind {
        let greeting: String
        switch hour {
        case 5..<10: greeting = "早。今天醒得比平时早一点。"
        case 10..<14: greeting = "在忙吗。"
        case 14..<18: greeting = "下午有点困。"
        case 18..<23: greeting = "今天过得怎么样。"
        default: greeting = "睡不着。"
        }

        var kinds: [OutreachKind] = [.greeting(greeting)]
        if settings.dailyShareEnabled { kinds.append(.dailyPhoto("随手拍的")) }
        kinds.append(.voiceNote("录了段话"))
        if edge.affinity > 0.4 { kinds.append(.recall("忽然想起你之前说过的事。")) }
        kinds.append(.greeting("……"))
        return kinds.randomElement() ?? .silence()
    }

    private func deliverOutreach(
        persona: Persona,
        conversation: Conversation,
        kind: OutreachKind
    ) async {
        let engine = ContextEngine(embedder: ProviderHub.shared.embedder)
        let settings = await store.currentSettings()
        let history = await store.messages(in: conversation.id)
        let memories = await store.memories(stream: persona.memoryStreamID)
        let canon = await store.bundlesFor(persona.id)
        let edge = await store.edge(from: persona.id, to: nil)

        var seedText = ""
        switch kind {
        case .greeting(let text): seedText = text
        case .recall(let text): seedText = text
        case .dailyPhoto(let text): seedText = text
        case .voiceNote(let text): seedText = text
        case .silence: return
        }

        var workingSet = await engine.workingSet(
            persona: persona, conversation: conversation, history: history,
            memories: memories, canon: canon, edge: edge, settings: settings,
            userInput: seedText
        )
        workingSet.systemPrompt += """

        【这一次是你主动找他的】
        现在轮到你发起对话。不要用「在吗」「好久不见」这种模板开场。
        直接说事，像真人突然想到什么就拿起手机打字那样。一两句就够。
        可以带上你的当下状态（在哪里、在做什么、心情如何）。
        """
        workingSet.messages[0] = LLMMessage(role: .system, content: workingSet.systemPrompt)

        var parser = CueStreamParser()
        var buffer = ""
        var cues: [PerformanceCue] = []
        var emotion: EmotionState?
        var monologue: String?

        do {
            let request = LLMRequest(
                messages: workingSet.messages,
                temperature: settings.temperature + 0.1,
                maxTokens: 260,
                model: settings.chatModel
            )
            for try await delta in ProviderHub.shared.llm.stream(request) {
                let out = parser.feed(delta)
                buffer += out.display
                if let emo = out.emotion { emotion = emo }
                if let inner = out.monologue { monologue = inner }
                cues.append(contentsOf: out.cues.filter { $0.channel != .pacing })
            }
        } catch {
            Log.autonomy.error("outreach failed: \(error.localizedDescription)")
            return
        }
        buffer += parser.finish().display

        let (clean, blocked) = settings.immersionGuardEnabled
            ? ImmersionGuard.scrub(buffer)
            : (buffer, 0)
        guard !clean.trimmed.isEmpty else { return }

        var message = Message(
            conversationID: conversation.id,
            authorID: persona.id,
            role: .persona,
            kind: .text,
            text: clean.trimmed
        )
        message.cues = cues
        message.emotion = emotion
        message.hidden.promptTokens = TokenEstimator.estimate(workingSet.messages)
        message.hidden.oocBlocks = blocked
        message.hidden.notes = ["自主发起"]

        // 日常照片：文字 + 图片
        if case .dailyPhoto = kind, settings.dailyShareEnabled {
            if let data = try? await ImageStudio(provider: ProviderHub.shared.image)
                .dailyPhoto(persona: persona, scene: seedText) {
                let file = try? await MediaStore.shared.saveImageData(data, prefix: "daily")
                message.kind = .dailyShare
                message.attachments = [
                    Attachment(kind: .image, fileName: file ?? "daily.jpg", caption: seedText)
                ]
            }
        }
        if case .voiceNote = kind {
            message.kind = .voiceNote
            message.attachments = [
                Attachment(kind: .audio, fileName: "outreach.m4a", duration: 4,
                           waveform: (0..<28).map { _ in Float.random(in: 0.15...1) },
                           transcript: clean)
            ]
        }
        if let monologue { message.hidden.innerMonologue = monologue }

        await store.append(message)
        Log.autonomy.info("outreach from \(persona.name): \(clean.prefix(24))")
    }

    // MARK: - 他们之间

    /// 把「用户视角看不见的关系」补全：任意两个认识的人之间都应该有边。
    private func reconcileInterCharacterEdges() async {
        let personas = await store.allPersonas()
        guard personas.count >= 2 else { return }
        var newEdges: [RelationshipEdge] = []
        let existing = await store.allEdges()

        for a in personas {
            for b in personas where a.id != b.id {
                guard a.id.uuidString < b.id.uuidString else { continue }
                let has = existing.contains { $0.fromID == a.id && $0.toID == b.id }
                if !has {
                    newEdges.append(RelationshipEdge(fromID: a.id, toID: b.id, affinity: 0.05, trust: 0.25))
                }
            }
        }
        if !newEdges.isEmpty { await store.upsertEdges(newEdges) }
    }

    /// 一次「幕间」：两个角色私下聊了几句。
    /// 产物：关系数值变化 + 一条隐藏日志。**聊天列表里什么都不会出现。**
    private func runInterCharacterScenes(limit: Int, settings: AppSettings) async {
        let personas = await store.allPersonas()
        guard personas.count >= 2 else { return }
        let edges = await store.allEdges()

        // 挑一对：张力高或者好感高的，最有戏
        let candidates = edges
            .filter { $0.toID != nil && (abs($0.affinity) > 0.2 || $0.tension > 0.3) }
            .sorted { ($0.tension + abs($0.affinity)) > ($1.tension + abs($1.affinity)) }
            .prefix(limit)

        for edge in candidates {
            guard let a = personas.first(where: { $0.id == edge.fromID }),
                  let b = personas.first(where: { $0.id == edge.toID }) else { continue }

            let prompt = """
            你是 \(a.core.name)。此刻你和 \(b.core.name) 单独待在一起，没有别人。
            你们目前的关系是「\(edge.kind.displayName)」，好感 \(String(format: "%.2f", edge.affinity))，张力 \(String(format: "%.2f", edge.tension))。

            \(a.core.seed.oneLine)
            \(b.core.seed.oneLine)

            写两到四行极短的对话，像两个人并排走着随口说话。
            不要客套，不要总结，不要旁白。用这个格式：
            \(a.core.name)：……
            \(b.core.name)：……
            """

            var output = ""
            do {
                let request = LLMRequest(
                    messages: [
                        LLMMessage(role: .system, content: "你写极简、克制、有潜台词的对话。"),
                        LLMMessage(role: .user, content: prompt),
                    ],
                    temperature: 1.0,
                    maxTokens: 240,
                    model: settings.chatModel
                )
                for try await delta in ProviderHub.shared.llm.stream(request) { output += delta }
            } catch {
                continue
            }
            guard !output.isBlank else { continue }

            // 用对话内容估一个"chemistry / friction"
            let (chemistry, friction) = Self.scoreScene(output, a: a.name, b: b.name)
            let updated = RelationshipEngine().advanceInterCharacter(
                edge, chemistry: chemistry, friction: friction, note: output.prefix(120).description
            )
            await store.upsert(updated.edge)
            if let milestone = updated.milestone {
                Log.autonomy.info("milestone: \(milestone)")
            }
            await InterCharacterLog.shared.record(
                a: a.name, b: b.name, transcript: output, at: Date()
            )
        }
    }

    private static func scoreScene(_ text: String, a: String, b: String) -> (Double, Double) {
        let warm = ["笑", "嗯", "谢谢", "一起", "好啊", "喜欢", "抱歉", "其实"]
        let cold = ["别", "不用", "算了", "随你", "没什么", "闭嘴", "懒得"]
        let warmHits = warm.filter { text.contains($0) }.count
        let coldHits = cold.filter { text.contains($0) }.count
        let chemistry = (Double(warmHits) / Double(max(1, warm.count)) * 3).clamped(0, 1)
        let friction = (Double(coldHits) / Double(max(1, cold.count)) * 4).clamped(0, 1)
        return (chemistry, friction)
    }
}

/// 幕间日志 —— 只存在于「潜意识层」。
/// 角色在聊天里可以提起「昨天我跟她聊到你了」，但你能看到的原文只有在这里。
actor InterCharacterLog {
    static let shared = InterCharacterLog()

    struct Entry: Codable, Sendable, Identifiable {
        var id = UUID()
        var a: String
        var b: String
        var transcript: String
        var at: Date
    }

    private var entries: [Entry] = []
    private let store = FileStore()

    init() {
        entries = store.load([Entry].self, from: "intercharacter.json") ?? []
    }

    func record(a: String, b: String, transcript: String, at: Date) {
        entries.append(Entry(a: a, b: b, transcript: transcript, at: at))
        entries = Array(entries.suffix(200))
        store.save(entries, to: "intercharacter.json")
    }

    func all() -> [Entry] { entries.sorted { $0.at > $1.at } }
}
