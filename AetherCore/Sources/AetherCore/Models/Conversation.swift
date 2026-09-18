import Foundation

enum ConversationKind: String, Codable, Sendable {
    case direct
    case group
    case moment      // 角色发的「日常」动态流
}

struct Participant: Codable, Hashable, Sendable {
    var personaID: UUID
    var joinedAt: Date = Date()
    var nickname: String?
    /// 群里的活跃权重：0 潜水 … 1 话痨
    var chattiness: Double = 0.5
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: ConversationKind
    var title: String
    var participants: [Participant]
    var createdAt: Date = Date()
    var lastActivityAt: Date = Date()
    var digest: ConversationDigest?
    var unreadCount: Int = 0
    var isPinned: Bool = false
    /// 群聊的「现场状态」：谁在、气氛如何
    var sceneNote: String?

    var isGroup: Bool { kind == .group }
    var personaIDs: [UUID] { participants.map { $0.personaID } }

    func participant(_ id: UUID) -> Participant? { participants.first { $0.personaID == id } }

    static func direct(with personaID: UUID, title: String) -> Conversation {
        Conversation(kind: .direct, title: title, participants: [Participant(personaID: personaID, chattiness: 1.0)])
    }

    static func group(title: String, members: [Participant]) -> Conversation {
        Conversation(kind: .group, title: title, participants: members)
    }
}
