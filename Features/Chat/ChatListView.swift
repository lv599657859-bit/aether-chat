import AetherCore
import SwiftUI

struct ChatListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var path: [Conversation] = []
    @State private var showNewChat = false
    @State private var showGroupCreator = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if env.conversations.isEmpty {
                    EmptyChatsView { showNewChat = true }
                } else {
                    List {
                        ForEach(env.conversations) { conversation in
                            NavigationLink(value: conversation) {
                                ConversationRow(conversation: conversation)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await env.store.deleteConversation(conversation.id); await env.refresh() }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("消息")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showNewChat = true } label: { Label("新的对话", systemImage: "person.badge.plus") }
                        Button { showGroupCreator = true } label: { Label("建个群", systemImage: "person.3") }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(conversation: conversation)
            }
            .sheet(isPresented: $showNewChat) {
                PersonaPickerSheet { persona in
                    showNewChat = false
                    Task {
                        let conversation = await env.openConversation(with: persona)
                        path.append(conversation)
                    }
                }
            }
            .sheet(isPresented: $showGroupCreator) {
                GroupCreateView { title, members in
                    showGroupCreator = false
                    Task {
                        let conversation = await env.createGroup(title: title, members: members)
                        path.append(conversation)
                    }
                }
            }
        }
    }
}

private struct ConversationRow: View {
    @Environment(AppEnvironment.self) private var env
    let conversation: Conversation
    @State private var lastText: String = ""
    @State private var lastTime: Date?

    private var persona: Persona? {
        guard let id = conversation.personaIDs.first else { return nil }
        return env.persona(id)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: (persona?.presentation.palette ?? ["#8A7BFF", "#FFB4C8"]).map { Color(hex: $0) },
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                if conversation.isGroup {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    Text(String(persona?.name.prefix(1) ?? "?"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title)
                        .font(.system(size: 16, weight: .semibold))
                    if conversation.isGroup {
                        Text("\(conversation.participants.count) 人")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let lastTime {
                        Text(lastTime, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(lastText.isEmpty ? "还没有聊过" : lastText)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: "#6C5CE7")))
            }
        }
        .task {
            let recent = await env.store.recentMessages(in: conversation.id, count: 1)
            if let last = recent.last {
                switch last.kind {
                case .voiceNote: lastText = "[语音]"
                case .image, .dailyShare: lastText = "[图片]"
                case .callLog: lastText = last.text
                case .sticker: lastText = last.text
                default: lastText = last.isFromUser ? "我：" + last.text : last.text
                }
                lastTime = last.createdAt
            }
        }
    }
}

private struct EmptyChatsView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("还没有人跟你说话")
                .font(.system(size: 16, weight: .medium))
            Button("去找一个人", action: action)
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#6C5CE7"))
        }
    }
}

/// 选人开聊。空列表时直接引导去创建 —— 第一次用的人不该看到死路。
struct PersonaPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onPick: (Persona) -> Void
    @State private var showStudio = false

    var body: some View {
        NavigationStack {
            Group {
                if env.personas.isEmpty {
                    VStack(spacing: 14) {
                        Text("你还没有任何人")
                            .font(.headline)
                        Text("可以先捏一个原创角色，也可以从喜欢的作品里复刻一个人。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("开始创造") { showStudio = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: "#6C5CE7"))
                    }
                    .padding()
                } else {
                    List(env.personas) { persona in
                        Button {
                            onPick(persona)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarDot(persona: persona, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.name).font(.system(size: 16, weight: .medium))
                                    Text(persona.hasCanon ? "复刻 · \(persona.core.sourceWork ?? "")" : persona.core.seed.oneLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("选一个人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showStudio = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showStudio) {
                PersonaStudioView()
            }
        }
    }
}

struct AvatarDot: View {
    let persona: Persona
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: persona.presentation.palette.map { Color(hex: $0) },
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            Text(String(persona.name.prefix(1)))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
