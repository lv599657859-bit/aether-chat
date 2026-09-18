import SwiftUI
import PhotosUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    let conversation: Conversation

    @State private var model: ChatViewModel?
    @State private var isExpanded = true
    @State private var showCall = false
    @State private var secretTaps = 0
    @State private var showGroupInfo = false

    private var persona: Persona? {
        guard let id = conversation.personaIDs.first else { return nil }
        return env.persona(id)
    }

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                if let persona, !conversation.isGroup {
                    AvatarStageView(
                        persona: persona,
                        coordinator: env.avatar,
                        stage: env.stage,
                        isExpanded: $isExpanded
                    )
                    .overlay(alignment: .bottom) { Divider().opacity(0.3) }
                }

                messageList

                if let model {
                    Composer(
                        onSend: { text, attachments in
                            Task { await model.send(text: text, attachments: attachments) }
                        },
                        onSendImage: { image in
                            Task { await model.sendImage(image) }
                        },
                        onStartCall: { showCall = true },
                        isGroup: conversation.isGroup
                    )
                }
            }

            if let camera = env.stage.camera {
                CameraShakeView(move: camera)
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(conversation.title)
                        .font(.system(size: 16, weight: .semibold))
                        .onTapGesture {
                            // 暗门之一：连点标题 5 次。正常使用永远碰不到。
                            secretTaps += 1
                            if secretTaps >= 5 {
                                secretTaps = 0
                                NotificationCenter.default.post(name: .aetherSecretTap, object: nil)
                            }
                        }
                    if let persona, !conversation.isGroup {
                        Text(persona.hasCanon
                             ? "\(persona.core.sourceWork ?? "") · \(persona.fidelity.displayName)"
                             : persona.core.seed.oneLine)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if conversation.isGroup {
                    Button { showGroupInfo = true } label: { Image(systemName: "info.circle") }
                } else {
                    Button { showCall = true } label: { Image(systemName: "phone") }
                }
            }
        }
        .task {
            if model == nil {
                let created = ChatViewModel(
                    conversationID: conversation.id,
                    director: env.director,
                    avatar: env.avatar
                )
                created.isGroupConversation = conversation.isGroup
                model = created
                await created.start()
                if let persona, !conversation.isGroup {
                    isExpanded = true
                    await env.avatar.activate(persona: persona, settings: env.settings)
                    env.avatar.apply(emotion: .neutral)
                }
            }
        }
        .onDisappear {
            model?.stop()
            env.avatar.shutdown()
            env.stage.clearAmbient()
        }
        .fullScreenCover(isPresented: $showCall) {
            if let persona {
                CallView(persona: persona, conversationID: conversation.id, coordinator: env.avatar)
            }
        }
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoSheet(conversation: conversation)
        }
    }

    private var backgroundGradient: some View {
        let palette = (persona?.presentation.palette ?? ["#8A7BFF", "#FFB4C8"]).map { Color(hex: $0) }
        return LinearGradient(
            colors: [
                palette.first?.opacity(0.06) ?? .clear,
                Color(uiColor: .systemBackground),
                palette.last?.opacity(0.04) ?? .clear,
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model?.messages ?? []) { message in
                        MessageBubble(
                            message: message,
                            persona: persona,
                            participants: env.personas.filter { conversation.personaIDs.contains($0.id) },
                            isGroup: conversation.isGroup,
                            onReact: { emoji in Task { await model?.react(emoji, to: message) } },
                            onRetry: { Task { await model?.retry(message) } }
                        )
                        .id(message.id)
                    }

                    if let typing = model?.typingPhrase, let authorID = model?.streamingAuthorID {
                        StreamingBubble(
                            author: env.persona(authorID),
                            phrase: typing,
                            text: model?.streamingText,
                            isGroup: conversation.isGroup
                        )
                        .id("streaming")
                    } else if let text = model?.streamingText, !text.isEmpty {
                        StreamingBubble(author: nil, phrase: nil, text: text, isGroup: false)
                            .id("streaming")
                    }

                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model?.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model?.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

/// 镜头指令的落地：屏幕整体位移。
private struct CameraShakeView: View {
    let move: String
    @State private var offset: CGSize = .zero

    var body: some View {
        Color.clear
            .offset(offset)
            .onAppear {
                switch move {
                case "shake":
                    withAnimation(.easeInOut(duration: 0.08).repeatCount(6, autoreverses: true)) {
                        offset = CGSize(width: 6, height: 0)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { offset = .zero }
                case "pushin":
                    withAnimation(.easeOut(duration: 0.5)) { offset = CGSize(width: 0, height: -3) }
                case "pullout":
                    withAnimation(.easeOut(duration: 0.5)) { offset = CGSize(width: 0, height: 3) }
                default:
                    offset = .zero
                }
            }
    }
}

/// 群聊信息：谁在群里、现在什么气氛。
struct GroupInfoSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation

    var body: some View {
        NavigationStack {
            List {
                Section("成员") {
                    ForEach(conversation.participants, id: \.personaID) { participant in
                        if let persona = env.persona(participant.personaID) {
                            HStack(spacing: 12) {
                                AvatarDot(persona: persona, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.name).font(.system(size: 15, weight: .medium))
                                    Text(participant.chattiness > 0.65 ? "话很多"
                                         : participant.chattiness > 0.4 ? "正常聊天" : "不太说话")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let note = conversation.sceneNote {
                    Section("此刻") { Text(note).font(.footnote) }
                }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }
}
