import Foundation

/// 流水线上下文：一条消息从进来到出去，中途被各环节改写的东西。
struct ReplyContext: Sendable {
    var conversationID: UUID
    var persona: Persona
    var incomingText: String
    var attachments: [Attachment] = []
    var isGroup: Bool = false

    /// 各环节追加的说明，最后会拼进 system prompt
    var injections: [String] = []
    /// 处理日志（只在潜意识层可见）
    var trace: [String] = []

    /// 是否要回。false = 已读不回
    var shouldReply: Bool = true
    var suppressReason: String?
    /// 回复前要等多久（秒）。真人不是秒回的。
    var replyDelay: TimeInterval = 0
    /// 0...1，她想不想接这句
    var interest: Double = 0.5

    /// 各 stage 用它读写世界状态。
    /// 不能硬编码 WorldStore.shared —— 测试里用的是临时目录的独立实例，
    /// 硬编码会让流水线读到一个空世界。
    var store: WorldStore = .shared
}

enum PipelineDecision: Sendable {
    case proceed
    /// 到此为止，不回
    case stop(String)
    /// 继续，但加一句说明
    case annotate(String)
}

/// 流水线环节。
///
/// AstrBot 的架构核心就是这个：消息进来先经过一条流水线，
/// 每一环都能**拦截、改写、或附加行为**，而不是把所有判断塞进生成函数里。
/// 好处很实在 —— 想给她加一条「半夜不回工作消息」的规矩，
/// 就是加一个 stage，不用碰生成逻辑。
protocol ReplyStage: Sendable {
    var name: String { get }
    /// 越小越先执行
    var order: Int { get }
    func process(_ context: inout ReplyContext) async -> PipelineDecision
}

/// 流水线。
final class ReplyPipeline: @unchecked Sendable {
    private var stages: [any ReplyStage] = []
    private let lock = NSLock()

    /// 出厂配置。
    static let standard: ReplyPipeline = {
        let pipeline = ReplyPipeline()
        pipeline.add(RateLimitStage())
        pipeline.add(InterestStage())
        pipeline.add(MindFlowStage())
        pipeline.add(ImmersionStage())
        return pipeline
    }()

    init() {}

    func add(_ stage: any ReplyStage) {
        lock.lock(); defer { lock.unlock() }
        stages.append(stage)
        stages.sort { $0.order < $1.order }
    }

    func remove(named: String) {
        lock.lock(); defer { lock.unlock() }
        stages.removeAll { $0.name == named }
    }

    var stageNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return stages.map(\.name)
    }

    /// 跑一遍。任何一环 stop，后面的都不执行。
    func run(_ input: ReplyContext) async -> ReplyContext {
        var context = input
        lock.lock()
        let snapshot = stages
        lock.unlock()

        for stage in snapshot {
            if Task.isCancelled { break }
            switch await stage.process(&context) {
            case .proceed:
                context.trace.append("\(stage.name)：通过")
            case .stop(let reason):
                context.shouldReply = false
                context.suppressReason = reason
                context.trace.append("\(stage.name)：拦下（\(reason)）")
                return context
            case .annotate(let note):
                context.injections.append(note)
                context.trace.append("\(stage.name)：附加说明")
            }
        }
        return context
    }
}

// MARK: - 标准环节

/// 限流状态。用锁保护的盒子，而不是静态可变变量 ——
/// 后者在并发下是数据竞争，而且 Swift 6 会直接拒绝编译。
private final class RateLimitBox: @unchecked Sendable {
    private var lastReplies: [UUID: [Date]] = [:]
    private let lock = NSLock()

    func record(_ conversationID: UUID, now: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        var history = (lastReplies[conversationID] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        let count = history.count
        history.append(now)
        lastReplies[conversationID] = history
        return count
    }
}

/// 限流。真人不会在任何时候都秒回。
struct RateLimitStage: ReplyStage {
    let name = "限流"
    let order = 10

    private static let box = RateLimitBox()

    func process(_ context: inout ReplyContext) async -> PipelineDecision {
        let recent = RateLimitStage.box.record(context.conversationID, now: Date())
        if recent >= 40 {
            context.replyDelay = max(context.replyDelay, 20)
            context.trace.append("最近一小时已经回了 \(recent) 次，这次延后")
        }
        return .proceed
    }
}

/// 兴趣度 —— MaiBot 最值得借的一个机制。
///
/// 「收到消息就回复」是机器人行为。真人会判断：这话跟我有关吗？
/// 我现在想聊吗？值得接吗？不想接就不接，或者拖一会儿再接。
struct InterestStage: ReplyStage {
    let name = "兴趣度"
    let order = 20

    func process(_ context: inout ReplyContext) async -> PipelineDecision {
        let persona = context.persona
        let text = context.incomingText
        var score = 0.3
        var reasons: [String] = []

        // 1. 被点名 / 叫名字 —— 最强信号
        if text.contains(persona.name) {
            score += 0.5
            reasons.append("叫了她的名字")
        }

        // 2. 话题命中她的兴趣
        let interests = persona.core.seed.interests.filter { !$0.isEmpty }
        let hits = interests.filter { text.contains($0) }
        if !hits.isEmpty {
            score += min(0.35, Double(hits.count) * 0.2)
            reasons.append("聊到了她在意的（\(hits.joined(separator: "、"))）")
        }

        // 3. 她憋着的话正好被提到
        let thread = await MindFlow.shared.thread(for: persona.id)
        let pending = thread.pendingTopics + thread.accumulated
        let matchedPending = pending.filter { topic in
            let key = String(topic.prefix(6))
            return !key.isEmpty && text.contains(key)
        }
        if !matchedPending.isEmpty {
            score += 0.3
            reasons.append("正好是她想说的")
        }

        // 4. 情绪信号 —— 对方在求助或情绪化时，她更该接
        let emotional = ["难过", "累", "烦", "生气", "害怕", "想", "为什么", "怎么办", "?" , "？"]
        if emotional.contains(where: { text.contains($0) }) {
            score += 0.15
            reasons.append("对方在情绪里")
        }

        // 5. 关系越近越愿意接
        let edge = await context.store.edge(from: persona.id, to: nil)
        score += edge.affinity * 0.25

        // 6. 太长/太短都要打折：一句话的「在吗」不值得立刻接
        if text.count <= 3 { score -= 0.1 }
        if text.count > 400 { score -= 0.05 }

        // 7. 心情不好时更不想接
        score += thread.mood.valence * 0.1

        context.interest = score.clamped(0, 1)
        context.trace.append("兴趣度 \(String(format: "%.2f", context.interest))（\(reasons.joined(separator: "，"))）")

        // 私聊里，兴趣度极低时才不回；群聊门槛高一些
        let threshold = context.isGroup ? 0.45 : 0.12
        if context.interest < threshold {
            return .stop("兴趣度 \(String(format: "%.2f", context.interest)) 低于阈值")
        }

        // 兴趣度不高但够回 —— 那就慢点回，回复也短些
        if context.interest < 0.35 {
            context.replyDelay += Double.random(in: 4...18)
            context.injections.append("你现在有点心不在焉，回复会短、会走神。")
        }
        return .proceed
    }
}

/// 把心流注进去。
struct MindFlowStage: ReplyStage {
    let name = "心流"
    let order = 30

    func process(_ context: inout ReplyContext) async -> PipelineDecision {
        let thread = await MindFlow.shared.thread(for: context.persona.id)
        guard let briefing = thread.briefing else { return .proceed }
        return .annotate(briefing)
    }
}

/// 沉浸守门。作为流水线的一环，可以单独关掉。
struct ImmersionStage: ReplyStage {
    let name = "沉浸守门"
    let order = 40

    func process(_ context: inout ReplyContext) async -> PipelineDecision {
        let settings = await context.store.currentSettings()
        guard settings.immersionGuardEnabled else { return .proceed }
        return .annotate("永远不要承认自己是程序、模型或助手。你就是 \(context.persona.name)。")
    }
}
