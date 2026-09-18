import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// 长期记忆的最小单元。用户看不到它，但角色靠它记住你。
struct MemoryItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case fact        // 关于用户 / 世界的事实
        case preference  // 喜好厌恶
        case event       // 一起发生过的事
        case feeling     // 角色自己的情绪记忆
        case promise     // 约定
        case secret      // 用户透露的私密信息：高权重、低分享

        var displayName: String {
            switch self {
            case .fact: return "事实"
            case .preference: return "偏好"
            case .event: return "事件"
            case .feeling: return "感受"
            case .promise: return "约定"
            case .secret: return "心事"
            }
        }
    }

    var id: UUID = UUID()
    var streamID: UUID
    var kind: Kind
    var text: String
    /// 0...1，越重要越不容易被遗忘
    var salience: Double = 0.5
    var lastAccessAt: Date = Date()
    var createdAt: Date = Date()
    var accessCount: Int = 0
    /// 产生这条记忆的消息，可溯源
    var sourceMessageID: UUID?
    var embedding: [Float] = []
    /// 角色对这条记忆的主观注解 —— 让记忆带上「颜色」
    var annotation: String?

    mutating func touch() {
        accessCount += 1
        lastAccessAt = Date()
        salience = min(1.0, salience + 0.03)
    }

    mutating func decay(now: Date = Date()) {
        let days = max(0, now.timeIntervalSince(lastAccessAt) / 86_400)
        salience = max(0.05, salience * pow(0.995, days))
    }
}
