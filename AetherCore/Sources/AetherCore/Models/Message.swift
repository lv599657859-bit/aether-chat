import Foundation

enum MessageRole: String, Codable, Sendable {
    case user, persona, system
}

enum MessageKind: String, Codable, Sendable {
    case text, voiceNote, image, sticker, callLog, systemEvent, dailyShare, gift, moment
}

enum DeliveryState: String, Codable, Sendable {
    case composing, sending, sent, delivered, read, failed
}

struct Attachment: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case image, audio, video, file }
    var kind: Kind
    var fileName: String
    var duration: TimeInterval?
    var waveform: [Float]?
    var caption: String?
    var width: Int?
    var height: Int?
    /// 语音消息的转写文本（隐藏层，供上下文用）
    var transcript: String?
}

/// 隐藏轨迹：模型的推理痕迹。**永不直接渲染进聊天气泡**，
/// 只在「潜意识层」里可见。这是沉浸感与可控性的分界线。
struct HiddenTrace: Codable, Hashable, Sendable {
    var recalledMemoryIDs: [UUID] = []
    var canonFactIDs: [UUID] = []
    var innerMonologue: String?
    var promptTokens: Int = 0
    var providerID: String = ""
    var modelID: String = ""
    var notes: [String] = []
    /// OOC 拦截次数：模型试图跳出角色被打回
    var oocBlocks: Int = 0
    var durationMS: Int = 0
}

struct Message: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var conversationID: UUID
    /// nil = 用户本人
    var authorID: UUID?
    var role: MessageRole
    var kind: MessageKind = .text
    var text: String = ""
    var attachments: [Attachment] = []
    var cues: [PerformanceCue] = []
    var emotion: EmotionState?
    var createdAt: Date = Date()
    var state: DeliveryState = .sent
    var replyToID: UUID?
    /// 表情回应：emoji -> 谁点的
    var reactions: [String: [UUID]] = [:]
    var hidden = HiddenTrace()

    var authorKey: String { authorID?.uuidString ?? "me" }
    var isFromUser: Bool { role == .user }
}

/// 会话摘要：上下文压缩的产物，藏在隐藏层里。
struct ConversationDigest: Codable, Hashable, Sendable {
    var conversationID: UUID
    var summary: String
    var coveredUpToMessageID: UUID?
    var openThreads: [String]
    var emotionalArc: String
    var updatedAt: Date = Date()
    var tokensSaved: Int = 0
}
