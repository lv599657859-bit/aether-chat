import Foundation

/// 角色之间的关系。用户要求：他们有可能自己发展出关系。
/// 关系不是静态标签，而是被每一次对话推动的连续量。
struct RelationshipEdge: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// 关系的拥有者
    var fromID: UUID
    /// nil 表示「角色 -> 用户」
    var toID: UUID?

    /// 好感：-1 厌恶 … +1 依恋
    var affinity: Double = 0.1
    /// 信任：0 戒备 … 1 无条件
    var trust: Double = 0.3
    /// 张力：0 平和 … 1 一触即发
    var tension: Double = 0.0
    /// 熟悉度：决定说话的随意程度
    var familiarity: Double = 0.05
    /// 权力：0 对方主导 … 1 我主导
    var power: Double = 0.5

    var kind: Kind = .stranger
    var milestones: [Milestone] = []
    var lastInteractionAt: Date = Date()

    enum Kind: String, Codable, Sendable, CaseIterable {
        case stranger, acquaintance, friend, closeFriend, family
        case rival, nemesis, crush, lover, exLover
        case mentor, student, colleague, subordinate, superior

        var displayName: String {
            switch self {
            case .stranger: return "陌生"
            case .acquaintance: return "认识"
            case .friend: return "朋友"
            case .closeFriend: return "挚友"
            case .family: return "家人"
            case .rival: return "竞争"
            case .nemesis: return "宿敌"
            case .crush: return "心动"
            case .lover: return "恋人"
            case .exLover: return "旧情"
            case .mentor: return "师长"
            case .student: return "学生"
            case .colleague: return "同僚"
            case .subordinate: return "部下"
            case .superior: return "上级"
            }
        }
    }

    struct Milestone: Codable, Hashable, Sendable {
        var label: String
        var at: Date
        var note: String
    }

    var isUserEdge: Bool { toID == nil }

    /// 时间衰减：关系会因为「不联系」变淡，张力会因为「放着不管」消退。
    mutating func decay(now: Date = Date()) {
        let hours = max(0, now.timeIntervalSince(lastInteractionAt) / 3600)
        let k = min(1, hours / 240)          // 10 天回到基线附近
        affinity += (affinity > 0 ? -0.0015 : 0.0015) * k
        tension *= (1 - 0.02 * k)
    }

    /// 关系类型由数值判定，而不是由设定宣告。
    mutating func reevaluateKind() {
        if tension > 0.8 && affinity < -0.4 {
            kind = .nemesis
        } else if affinity > 0.85 && trust > 0.8 {
            kind = (kind == .lover) ? .lover : .closeFriend
        } else if affinity > 0.6 && trust > 0.6 {
            kind = .friend
        } else if affinity > 0.25 {
            kind = .acquaintance
        } else if affinity < -0.3 {
            kind = .rival
        } else {
            kind = .stranger
        }
    }
}

/// 一次「关系事件」：和解、决裂、心动。写进里程碑，也可能被角色自己提起。
struct RelationshipEvent: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var edgeID: UUID
    var label: String
    var note: String
    var at: Date = Date()
}
