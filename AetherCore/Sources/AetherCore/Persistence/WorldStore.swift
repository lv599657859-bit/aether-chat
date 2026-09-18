import Foundation

enum WorldEvent: Sendable {
    case personasChanged
    case conversationsChanged
    case messagesChanged(UUID)
    case edgesChanged
    case memoriesChanged(UUID)
    case settingsChanged
}

/// 全app唯一的世界状态。所有角色、会话、消息、关系、记忆都从这里进出。
///
/// 设计要点：**这是隐藏层的物理位置**。UI 只读它需要的切片，
/// 潜意识层面板读全部，而聊天界面拿不到任何元信息。
actor WorldStore {
    static let shared = WorldStore()

    private let store: FileStore

    private var personas: [UUID: Persona] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var messages: [UUID: [Message]] = [:]         // conversationID -> messages
    private var edges: [UUID: RelationshipEdge] = [:]
    private var memories: [UUID: [MemoryItem]] = [:]      // streamID -> memories
    private var bundles: [UUID: CanonBundle] = [:]
    private var settings: AppSettings = .standard

    private var listeners: [UUID: AsyncStream<WorldEvent>.Continuation] = [:]

    init(store: FileStore = FileStore()) {
        self.store = store
    }

    // MARK: - 事件流

    nonisolated func events() -> AsyncStream<WorldEvent> {
        AsyncStream { continuation in
            let token = UUID()
            Task { await self.register(token: token, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregister(token: token) }
            }
        }
    }

    private func register(token: UUID, continuation: AsyncStream<WorldEvent>.Continuation) {
        listeners[token] = continuation
    }

    private func unregister(token: UUID) {
        listeners[token] = nil
    }

    private func broadcast(_ event: WorldEvent) {
        for continuation in listeners.values { continuation.yield(event) }
    }

    // MARK: - 启动

    func bootstrap() {
        settings = store.load(AppSettings.self, from: "settings.json") ?? .standard
        personas = store.load([UUID: Persona].self, from: "personas.json") ?? [:]
        conversations = store.load([UUID: Conversation].self, from: "conversations.json") ?? [:]
        edges = store.load([UUID: RelationshipEdge].self, from: "edges.json") ?? [:]
        for id in conversations.keys {
            messages[id] = store.load([Message].self, from: "messages/\(id.uuidString).json") ?? []
        }
        for persona in personas.values {
            memories[persona.memoryStreamID] =
                store.load([MemoryItem].self, from: "memories/\(persona.memoryStreamID.uuidString).json") ?? []
        }
        Log.app.info("WorldStore bootstrapped: \(self.personas.count) personas, \(self.conversations.count) conversations")
    }

    private func persistPersonas() { store.save(personas, to: "personas.json") }
    private func persistConversations() { store.save(conversations, to: "conversations.json") }
    private func persistEdges() { store.save(edges, to: "edges.json") }
    private func persistMessages(_ id: UUID) { store.save(messages[id] ?? [], to: "messages/\(id.uuidString).json") }

    // MARK: - 设置

    func currentSettings() -> AppSettings { settings }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        store.save(settings, to: "settings.json")
        broadcast(.settingsChanged)
    }

    // MARK: - 人格

    func allPersonas() -> [Persona] {
        personas.values.sorted { $0.core.createdAt < $1.core.createdAt }
    }

    func persona(_ id: UUID) -> Persona? { personas[id] }

    func personas(_ ids: [UUID]) -> [Persona] { ids.compactMap { personas[$0] } }

    func upsert(_ persona: Persona) {
        personas[persona.id] = persona
        persistPersonas()
        broadcast(.personasChanged)
    }

    func updatePersona(_ id: UUID, _ mutate: (inout Persona) -> Void) {
        guard var p = personas[id] else { return }
        mutate(&p)
        personas[id] = p
        persistPersonas()
        broadcast(.personasChanged)
    }

    func deletePersona(_ id: UUID) {
        guard let p = personas.removeValue(forKey: id) else { return }
        memories[p.memoryStreamID] = nil
        if let bundleID = p.core.canonBundleID { bundles[bundleID] = nil }
        persistPersonas()
        broadcast(.personasChanged)
    }

    // MARK: - Canon

    func saveBundle(_ bundle: CanonBundle) {
        bundles[bundle.id] = bundle
        store.save(bundle, to: "canon/\(bundle.id.uuidString).json")
    }

    func bundle(_ id: UUID) -> CanonBundle? {
        if let cached = bundles[id] { return cached }
        guard let loaded = store.load(CanonBundle.self, from: "canon/\(id.uuidString).json") else { return nil }
        bundles[id] = loaded
        return loaded
    }

    func bundlesFor(_ personaID: UUID) -> CanonBundle? {
        guard let p = personas[personaID], let id = p.core.canonBundleID else { return nil }
        return bundle(id)
    }

    // MARK: - 会话

    func allConversations() -> [Conversation] {
        conversations.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func conversation(_ id: UUID) -> Conversation? { conversations[id] }

    func upsert(_ conversation: Conversation) {
        conversations[conversation.id] = conversation
        persistConversations()
        broadcast(.conversationsChanged)
    }

    func updateConversation(_ id: UUID, _ mutate: (inout Conversation) -> Void) {
        guard var c = conversations[id] else { return }
        mutate(&c)
        conversations[id] = c
        persistConversations()
        broadcast(.conversationsChanged)
    }

    func deleteConversation(_ id: UUID) {
        conversations[id] = nil
        messages[id] = nil
        store.delete("messages/\(id.uuidString).json")
        persistConversations()
        broadcast(.conversationsChanged)
    }

    func directConversation(with personaID: UUID) -> Conversation? {
        conversations.values.first { !$0.isGroup && $0.personaIDs == [personaID] }
    }

    // MARK: - 消息

    func messages(in conversationID: UUID, limit: Int = 500) -> [Message] {
        let all = messages[conversationID] ?? []
        return all.count <= limit ? all : Array(all.suffix(limit))
    }

    func recentMessages(in conversationID: UUID, count: Int) -> [Message] {
        Array((messages[conversationID] ?? []).suffix(count))
    }

    func message(_ id: UUID, in conversationID: UUID) -> Message? {
        (messages[conversationID] ?? []).first { $0.id == id }
    }

    func append(_ message: Message) {
        var list = messages[message.conversationID] ?? []
        list.append(message)
        messages[message.conversationID] = list
        persistMessages(message.conversationID)
        if var c = conversations[message.conversationID] {
            c.lastActivityAt = message.createdAt
            if message.role == .persona { c.unreadCount += 1 }
            conversations[message.conversationID] = c
            persistConversations()
        }
        broadcast(.messagesChanged(message.conversationID))
    }

    func append(contentsOf newMessages: [Message], to conversationID: UUID) {
        guard !newMessages.isEmpty else { return }
        var list = messages[conversationID] ?? []
        list.append(contentsOf: newMessages)
        messages[conversationID] = list
        persistMessages(conversationID)
        if var c = conversations[conversationID] {
            c.lastActivityAt = newMessages.last!.createdAt
            conversations[conversationID] = c
            persistConversations()
        }
        broadcast(.messagesChanged(conversationID))
    }

    func deleteMessage(_ id: UUID, in conversationID: UUID) {
        messages[conversationID]?.removeAll { $0.id == id }
        persistMessages(conversationID)
        broadcast(.messagesChanged(conversationID))
    }

    /// 撤回/遗忘：把一段历史从上下文里抹掉（消息还在，但不再进入 prompt）。
    func setDigest(_ digest: ConversationDigest, for conversationID: UUID) {
        guard var c = conversations[conversationID] else { return }
        c.digest = digest
        conversations[conversationID] = c
        persistConversations()
    }

    // MARK: - 关系

    func allEdges() -> [RelationshipEdge] { Array(edges.values) }

    func edge(from: UUID, to: UUID?) -> RelationshipEdge {
        if let existing = edges.values.first(where: { $0.fromID == from && $0.toID == to }) {
            return existing
        }
        return RelationshipEdge(fromID: from, toID: to)
    }

    func edges(from: UUID) -> [RelationshipEdge] {
        edges.values.filter { $0.fromID == from }
    }

    func upsert(_ edge: RelationshipEdge) {
        if let existing = edges.values.first(where: { $0.fromID == edge.fromID && $0.toID == edge.toID }) {
            var updated = edge
            updated.id = existing.id
            edges[existing.id] = updated
        } else {
            edges[edge.id] = edge
        }
        persistEdges()
        broadcast(.edgesChanged)
    }

    func upsertEdges(_ list: [RelationshipEdge]) {
        for e in list { upsertSilently(e) }
        persistEdges()
        broadcast(.edgesChanged)
    }

    private func upsertSilently(_ edge: RelationshipEdge) {
        if let existing = edges.values.first(where: { $0.fromID == edge.fromID && $0.toID == edge.toID }) {
            var updated = edge
            updated.id = existing.id
            edges[existing.id] = updated
        } else {
            edges[edge.id] = edge
        }
    }

    // MARK: - 记忆

    func memories(stream: UUID) -> [MemoryItem] {
        memories[stream] ?? []
    }

    func upsertMemories(_ list: [MemoryItem]) {
        guard let stream = list.first?.streamID else { return }
        var bucket = memories[stream] ?? []
        for item in list {
            if let idx = bucket.firstIndex(where: { $0.id == item.id }) {
                bucket[idx] = item
            } else {
                bucket.append(item)
            }
        }
        memories[stream] = bucket
        store.save(bucket, to: "memories/\(stream.uuidString).json")
        broadcast(.memoriesChanged(stream))
    }

    func forget(memoryID: UUID, stream: UUID) {
        memories[stream]?.removeAll { $0.id == memoryID }
        store.save(memories[stream] ?? [], to: "memories/\(stream.uuidString).json")
        broadcast(.memoriesChanged(stream))
    }

    /// 让记忆随时间自然褪色 —— 每次冷启动跑一次。
    func decayMemories() {
        for (stream, var bucket) in memories {
            for i in bucket.indices { bucket[i].decay() }
            memories[stream] = bucket
            store.save(bucket, to: "memories/\(stream.uuidString).json")
        }
    }

    // MARK: - 量子统计（给潜意识层看）

    struct Footprint: Sendable {
        var personaCount = 0
        var conversationCount = 0
        var messageCount = 0
        var memoryCount = 0
        var edgeCount = 0
    }

    func footprint() -> Footprint {
        var f = Footprint()
        f.personaCount = personas.count
        f.conversationCount = conversations.count
        f.messageCount = messages.values.reduce(0) { $0 + $1.count }
        f.memoryCount = memories.values.reduce(0) { $0 + $1.count }
        f.edgeCount = edges.count
        return f
    }
}
