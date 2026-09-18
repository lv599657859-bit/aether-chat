import SwiftUI
import Observation

@MainActor
@Observable
final class ChatViewModel {
    let conversationID: UUID
    private(set) var messages: [Message] = []
    /// 正在流式生成的那条（还没落库），用于实时打字效果
    private(set) var streamingText: String?
    private(set) var streamingAuthorID: UUID?
    private(set) var typingPhrase: String?
    private(set) var isGenerating = false
    private(set) var errorText: String?

    /// 由视图在加载后写入，避免 init 里做异步查询
    var isGroupConversation = false

    private let store: WorldStore
    private let orchestrator: ChatOrchestrator
    private let groupDirector: GroupDirector
    private let director: PerformanceDirector
    private let avatar: AvatarCoordinator
    private var observerTask: Task<Void, Never>?

    init(
        conversationID: UUID,
        store: WorldStore = .shared,
        director: PerformanceDirector,
        avatar: AvatarCoordinator
    ) {
        self.conversationID = conversationID
        self.store = store
        self.orchestrator = ChatOrchestrator(store: store)
        self.groupDirector = GroupDirector(store: store)
        self.director = director
        self.avatar = avatar
    }

    func start() async {
        await load()
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.store.events() {
                if Task.isCancelled { return }
                if case .messagesChanged(let id) = event, id == self.conversationID {
                    await self.load()
                }
            }
        }
    }

    func stop() {
        observerTask?.cancel()
        observerTask = nil
    }

    func load() async {
        messages = await store.messages(in: conversationID)
    }

    // MARK: - 发送

    func send(text: String, attachments: [Attachment] = []) async {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard !isGenerating else { return }

        isGenerating = true
        errorText = nil
        streamingText = ""
        typingPhrase = nil

        let stream = isGroupConversation
            ? groupDirector.run(conversationID: conversationID, userText: trimmed)
            : orchestrator.send(text: trimmed, attachments: attachments, in: conversationID)

        for await event in stream {
            switch event {
            case .userMessage(let message):
                messages.append(message)

            case .typingStarted(let personaID, let phrase):
                typingPhrase = phrase
                streamingAuthorID = personaID
                streamingText = ""

            case .partial(let text, let emotion):
                streamingText = text
                if let emotion { avatar.apply(emotion: emotion, intensity: 1) }

            case .actions(let personaID, let cues):
                streamingAuthorID = personaID
                for cue in cues {
                    director.dispatch(cue, personaID: personaID, avatar: avatar)
                }

            case .emotionChanged(_, let emotion):
                avatar.apply(emotion: emotion, intensity: 1)

            case .segment(let message):
                // 一条说完立刻落屏并清空流式缓冲 —— 真人也是分条发的
                messages.append(message)
                streamingText = nil
                typingPhrase = nil

            case .finished:
                streamingText = nil
                typingPhrase = nil
                streamingAuthorID = nil

            case .failed(let reason):
                errorText = reason
                streamingText = nil
                typingPhrase = nil
                Log.llm.error("chat send failed: \(reason)")
            }
        }

        isGenerating = false
        await load()
    }

    func retry(_ message: Message) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index > 0 else { return }
        let previousUser = messages[..<index].last { $0.isFromUser }
        await store.deleteMessage(message.id, in: conversationID)
        await send(text: previousUser?.text ?? "")
    }

    func react(_ emoji: String, to message: Message) async {
        var updated = message
        var actors = updated.reactions[emoji] ?? []
        if !actors.isEmpty {
            actors.removeLast()
        } else {
            actors.append(message.authorID ?? UUID())
        }
        updated.reactions[emoji] = actors.isEmpty ? nil : actors
        await store.deleteMessage(message.id, in: conversationID)
        await store.append(updated)
        await load()
    }

    func sendSticker(_ emoji: String) async {
        var message = Message(
            conversationID: conversationID, authorID: nil, role: .user,
            kind: .sticker, text: emoji
        )
        message.state = .delivered
        await store.append(message)
        await load()
    }

    /// 发一张自己的照片 —— 角色会真的「看图」，而不是只收到一个文件。
    func sendImage(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let fileName = (try? await MediaStore.shared.saveImageData(data, prefix: "user")) ?? "image.jpg"
        let attachment = Attachment(
            kind: .image, fileName: fileName,
            width: Int(image.size.width), height: Int(image.size.height)
        )
        await send(text: "", attachments: [attachment])
    }
}
