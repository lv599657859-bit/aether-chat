import Foundation

/// 关系引擎。
///
/// 用户的要求是「他们甚至有可能自己发展出关系」。所以关系不能是创建时写死的标签，
/// 必须是被每一次互动推动的连续量，并且能在没人管的时候自己走。
///
/// 这一层的输出有两个：
///   1. 数值（好感/信任/张力/熟悉/权力）—— 只在潜意识层可见
///   2. 语气指令 —— 注入 prompt，让数值真的改变她说话的方式
final class RelationshipEngine: @unchecked Sendable {
    /// 用户话语里的情感信号。离线可跑，不依赖模型。
    private struct Signal {
        let pattern: String
        let affinity: Double
        let trust: Double
        let tension: Double
        let familiarity: Double
        let milestone: String?
    }

    private let signals: [Signal] = [
        Signal(pattern: "谢谢你|感谢|多亏了你", affinity: 0.05, trust: 0.03, tension: -0.05, familiarity: 0.02, milestone: nil),
        Signal(pattern: "对不起|抱歉|是我不对", affinity: 0.03, trust: 0.04, tension: -0.12, familiarity: 0.02, milestone: "和解"),
        Signal(pattern: "喜欢你|爱你|想你", affinity: 0.10, trust: 0.04, tension: 0.02, familiarity: 0.04, milestone: "表白"),
        Signal(pattern: "好可爱|真好看|厉害了|太棒了", affinity: 0.06, trust: 0.01, tension: 0, familiarity: 0.03, milestone: nil),
        Signal(pattern: "你真笨|闭嘴|讨厌你|滚", affinity: -0.10, trust: -0.04, tension: 0.14, familiarity: 0.01, milestone: "冲突"),
        Signal(pattern: "骗我|骗子|不信你", affinity: -0.06, trust: -0.12, tension: 0.10, familiarity: 0, milestone: nil),
        Signal(pattern: "我告诉你一个|别告诉别人|只跟你说|秘密", affinity: 0.05, trust: 0.12, tension: 0, familiarity: 0.05, milestone: "交心"),
        Signal(pattern: "约好|说好了|答应你|一言为定", affinity: 0.05, trust: 0.08, tension: 0, familiarity: 0.03, milestone: "约定"),
        Signal(pattern: "你最近怎么样|在干嘛|吃了吗|睡了吗", affinity: 0.02, trust: 0.01, tension: 0, familiarity: 0.04, milestone: nil),
        Signal(pattern: "我难过|我累|压力好大|撑不住", affinity: 0.06, trust: 0.09, tension: -0.02, familiarity: 0.04, milestone: "倾诉"),
        Signal(pattern: "好久不见|这么久|你去哪了", affinity: 0.02, trust: 0, tension: 0.06, familiarity: 0.02, milestone: nil),
    ]

    /// 用户 -> 角色的边，在每轮之后更新。
    func updateUserEdge(_ edge: RelationshipEdge, userText: String, personaReplied: Bool) -> RelationshipEdge {
        var updated = edge
        let text = userText.lowercased()

        for signal in signals where text.range(of: signal.pattern, options: .regularExpression) != nil {
            updated.affinity = (updated.affinity + signal.affinity).clamped(-1, 1)
            updated.trust = (updated.trust + signal.trust).clamped(0, 1)
            updated.tension = (updated.tension + signal.tension).clamped(0, 1)
            updated.familiarity = (updated.familiarity + signal.familiarity).clamped(0, 1)
            if let label = signal.milestone, updated.affinity > 0.5 || signal.tension > 0 {
                updated.milestones.append(.init(label: label, at: Date(), note: userText.prefix(40).description))
                updated.milestones = Array(updated.milestones.suffix(20))
            }
        }

        // 聊天本身就会变熟，只是很慢
        updated.familiarity = (updated.familiarity + 0.008).clamped(0, 1)
        // 你在意她，她的话就有分量
        if personaReplied { updated.power = (updated.power - 0.002).clamped(0, 1) }
        updated.lastInteractionAt = Date()
        updated.reevaluateKind()
        return updated
    }

    /// 角色 -> 角色：群聊里的一次发言，会改变发言者对在场其他人的观感。
    func updateInterCharacterEdges(
        speaker: UUID,
        audience: [UUID],
        speakerText: String,
        speakerEmotion: EmotionState?
    ) -> [RelationshipEdge] {
        var results: [RelationshipEdge] = []
        for other in audience where other != speaker {
            var edge = RelationshipEdge(fromID: speaker, toID: other, familiarity: 0.15)
            let warmth = speakerEmotion.map { ($0.valence + 1) / 2 } ?? 0.5
            edge.affinity = (0.1 + warmth * 0.25).clamped(-1, 1)
            edge.familiarity = 0.18
            edge.trust = 0.35
            edge.milestones = []
            edge.lastInteractionAt = Date()
            edge.reevaluateKind()
            results.append(edge)
        }
        return results
    }

    /// 两个角色在一次私下对话之后的关系推进。
    /// 这就是「他们自己发展出关系」的执行点：群聊之外，他们也在互相认识。
    func advanceInterCharacter(
        _ edge: RelationshipEdge,
        chemistry: Double,
        friction: Double,
        note: String
    ) -> (edge: RelationshipEdge, milestone: String?) {
        var updated = edge
        updated.affinity = (updated.affinity + chemistry * 0.06).clamped(-1, 1)
        updated.familiarity = (updated.familiarity + 0.05).clamped(0, 1)
        updated.tension = (updated.tension + friction * 0.08).clamped(0, 1)
        updated.trust = (updated.trust + chemistry * 0.03).clamped(0, 1)
        updated.lastInteractionAt = Date()

        var milestone: String?
        let before = edge.kind
        updated.reevaluateKind()
        if updated.kind != before {
            milestone = "关系变化：\(before.displayName) -> \(updated.kind.displayName)"
            updated.milestones.append(.init(label: milestone!, at: Date(), note: note))
            updated.milestones = Array(updated.milestones.suffix(20))
        }
        return (updated, milestone)
    }

    /// 时间流逝：所有关系缓慢回归基线。
    func tick(edges: [RelationshipEdge], now: Date = Date()) -> [RelationshipEdge] {
        edges.map { edge in
            var e = edge
            e.decay(now: now)
            e.reevaluateKind()
            return e
        }
    }

    /// 给潜意识层用的一句话人话描述。
    static func describe(_ edge: RelationshipEdge, from: String, to: String) -> String {
        let tone: String
        switch edge.affinity {
        case ..<(-0.3): tone = "明显抵触"
        case ..<0.15: tone = "保持距离"
        case ..<0.5: tone = "有好感"
        case ..<0.8: tone = "信任"
        default: tone = "依赖"
        }
        return "\(from) 对 \(to)：「\(edge.kind.displayName)」· \(tone)"
    }
}
