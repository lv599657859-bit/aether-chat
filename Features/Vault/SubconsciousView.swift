import AetherCore
import SwiftUI

/// 潜意识层。
///
/// 这是整个 app 里唯一一处「说人话的地方」—— 元信息、记忆、关系数值、
/// 内部日志、以及模型实际看到的完整上下文，全部摊在这里。
///
/// 它没有入口按钮。你得连点聊天标题 5 次，再通过生物识别才能进来。
/// 用户的要求是「不显示在明面上」，但**必须真的存在** ——
/// 因为不可观测的上下文管理等于没有上下文管理。
struct SubconsciousView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var section: Section = .overview
    @State private var footprint: WorldStore.Footprint?
    @State private var selectedPersonaID: UUID?
    @State private var memories: [MemoryItem] = []
    @State private var edges: [RelationshipEdge] = []
    @State private var scenes: [InterCharacterLog.Entry] = []
    @State private var monologues: [(name: String, text: String, at: Date)] = []
    @State private var inspectorText: String?
    @State private var inspectorNotes: [String] = []
    @State private var isInspecting = false

    enum Section: String, CaseIterable {
        case overview, memory, context, relationship, scenes, settings

        var title: String {
            switch self {
            case .overview: return "概览"
            case .memory: return "记忆"
            case .context: return "上下文"
            case .relationship: return "关系"
            case .scenes: return "幕间"
            case .settings: return "开关"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                List {
                    switch section {
                    case .overview: overviewSection
                    case .memory: memorySection
                    case .context: contextSection
                    case .relationship: relationshipSection
                    case .scenes: scenesSection
                    case .settings: settingsSection
                    }
                }
            }
            .navigationTitle("潜意识层")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .task { await load() }
    }

    // MARK: - 概览

    @ViewBuilder
    private var overviewSection: some View {
        if let footprint {
            Section("她脑子里现在有多少东西") {
                statRow("角色", "\(footprint.personaCount)")
                statRow("会话", "\(footprint.conversationCount)")
                statRow("消息", "\(footprint.messageCount)")
                statRow("长期记忆", "\(footprint.memoryCount)")
                statRow("关系边", "\(footprint.edgeCount)")
            }
            Section {
                Text("这些数字不会出现在任何聊天界面上。它们只在这里存在。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("服务") {
                statRow("生成引擎", ProviderHub.shared.llm.displayName)
                statRow("离线演示", env.isOfflineDemo ? "是（未配置密钥）" : "否")
                statRow("向量化", ProviderHub.shared.embedder is HashingEmbedder ? "本地哈希（离线）" : "云端 embedding")
            }
        }
    }

    // MARK: - 记忆

    @ViewBuilder
    private var memorySection: some View {
        Section("看谁") {
            Picker("角色", selection: $selectedPersonaID) {
                Text("选择").tag(UUID?.none)
                ForEach(env.personas) { persona in
                    Text(persona.name).tag(UUID?.some(persona.id))
                }
            }
            .onChange(of: selectedPersonaID) { _, _ in Task { await loadMemories() } }
        }

        if memories.isEmpty {
            Section {
                Text("还没有记忆。多聊几句，她会开始记住你。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Section("长期记忆（\(memories.count) 条）") {
                ForEach(memories.sorted { $0.salience > $1.salience }) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.kind.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color(hex: "#6C5CE7").opacity(0.14)))
                                .foregroundStyle(Color(hex: "#6C5CE7"))
                            Text(String(format: "重要度 %.2f", item.salience))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Text("唤起 \(item.accessCount) 次")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(item.text).font(.system(size: 13))
                        if let annotation = item.annotation, !annotation.isEmpty {
                            Text("她自己的注：" + annotation)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                guard let id = selectedPersonaID,
                                      let persona = env.persona(id) else { return }
                                await env.store.forget(memoryID: item.id, stream: persona.memoryStreamID)
                                await loadMemories()
                            }
                        } label: { Label("让她忘掉", systemImage: "trash") }
                    }
                }
            }
        }
    }

    // MARK: - 上下文

    @ViewBuilder
    private var contextSection: some View {
        Section {
            Text("这里能看到模型实际收到的全部内容。上下文引擎会自动压缩、检索、注入 —— 但压缩结果是否正确，只有这里能验证。")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("会话摘要") {
            ForEach(env.conversations.filter { !$0.isGroup }) { conversation in
                if let digest = conversation.digest {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title).font(.system(size: 13, weight: .medium))
                        Text(digest.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        if !digest.openThreads.isEmpty {
                            Text("未完结：" + digest.openThreads.joined(separator: " / "))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text("已节省约 \(digest.tokensSaved) tokens · \(digest.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        Text(conversation.title).font(.system(size: 13))
                        Spacer()
                        Text("尚未压缩").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section("内心独白") {
            if monologues.isEmpty {
                Text("还没有记录。").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(monologues.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(entry.text).font(.system(size: 13))
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }

        Section("上下文透视") {
            Picker("看谁", selection: $selectedPersonaID) {
                Text("选择").tag(UUID?.none)
                ForEach(env.personas) { persona in Text(persona.name).tag(UUID?.some(persona.id)) }
            }
            Button {
                Task { await inspect() }
            } label: {
                if isInspecting {
                    HStack { ProgressView(); Text("正在组装…") }
                } else {
                    Label("组装一次并查看", systemImage: "doc.text.magnifyingglass")
                }
            }
            .disabled(selectedPersonaID == nil || isInspecting)

            if let inspectorText {
                DisclosureGroup("组装日志") {
                    ForEach(inspectorNotes, id: \.self) { note in
                        Text("· " + note).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    Text(inspectorText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
        }
    }

    // MARK: - 关系

    @ViewBuilder
    private var relationshipSection: some View {
        Section("她对你") {
            ForEach(env.personas) { persona in
                let edge = edges.first { $0.fromID == persona.id && $0.toID == nil }
                if let edge {
                    EdgeCard(from: persona.name, to: "你", edge: edge)
                }
            }
        }

        Section("他们之间") {
            let interEdges = edges.filter { $0.toID != nil }
            if interEdges.isEmpty {
                Text("他们还没认识。").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(interEdges) { edge in
                    if let from = env.persona(edge.fromID),
                       let toID = edge.toID, let to = env.persona(toID) {
                        EdgeCard(from: from.name, to: to.name, edge: edge)
                    }
                }
            }
        }
    }

    // MARK: - 幕间

    @ViewBuilder
    private var scenesSection: some View {
        Section {
            Text("你不看的时候，他们之间发生的事。\n它们不会出现在聊天列表里 —— 只会改变关系，然后在某次聊天里被自然提起。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if scenes.isEmpty {
            Section { Text("还没有。").font(.footnote).foregroundStyle(.secondary) }
        } else {
            ForEach(scenes) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(entry.a) × \(entry.b)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(entry.transcript)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 开关

    @ViewBuilder
    private var settingsSection: some View {
        Section("上下文") {
            Toggle("自动管理上下文", isOn: Binding(
                get: { env.settings.contextEngineEnabled },
                set: { value in Task { await env.updateSettings { $0.contextEngineEnabled = value } } }
            ))
            Stepper("压缩阈值 \(env.settings.autoSummarizeThreshold) 字",
                    value: Binding(
                        get: { env.settings.autoSummarizeThreshold },
                        set: { value in Task { await env.updateSettings { $0.autoSummarizeThreshold = value } } }
                    ),
                    in: 2000...30000, step: 1000)
            Stepper("每次唤起 \(env.settings.retrievalTopK) 条记忆",
                    value: Binding(
                        get: { env.settings.retrievalTopK },
                        set: { value in Task { await env.updateSettings { $0.retrievalTopK = value } } }
                    ),
                    in: 1...20)
            Toggle("保留内心独白", isOn: Binding(
                get: { env.settings.keepInnerMonologue },
                set: { value in Task { await env.updateSettings { $0.keepInnerMonologue = value } } }
            ))
        }

        Section("沉浸保护") {
            Toggle("沉浸守门（拦截出戏发言）", isOn: Binding(
                get: { env.settings.immersionGuardEnabled },
                set: { value in Task { await env.updateSettings { $0.immersionGuardEnabled = value } } }
            ))
            Toggle("入口常显", isOn: Binding(
                get: { env.settings.subconsciousEntryVisible },
                set: { value in Task { await env.updateSettings { $0.subconsciousEntryVisible = value } } }
            ))
            Toggle("进入需要 \(Vault.biometryKind)", isOn: Binding(
                get: { env.settings.vaultBiometryRequired },
                set: { value in Task { await env.updateSettings { $0.vaultBiometryRequired = value } } }
            ))
        }

        Section("自主性") {
            Toggle("角色之间会自己聊天", isOn: Binding(
                get: { env.settings.interCharacterChatterEnabled },
                set: { value in Task { await env.updateSettings { $0.interCharacterChatterEnabled = value } } }
            ))
            Toggle("会主动给你发消息", isOn: Binding(
                get: { env.settings.autonomyEnabled },
                set: { value in Task { await env.updateSettings { $0.autonomyEnabled = value } } }
            ))
        }
    }

    // MARK: - 数据

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        footprint = await env.store.footprint()
        edges = await env.store.allEdges()
        scenes = await InterCharacterLog.shared.all()
        if selectedPersonaID == nil { selectedPersonaID = env.personas.first?.id }
        await loadMemories()
        await loadMonologues()
    }

    private func loadMemories() async {
        guard let id = selectedPersonaID, let persona = env.persona(id) else {
            memories = []
            return
        }
        memories = await env.store.memories(stream: persona.memoryStreamID)
    }

    private func loadMonologues() async {
        var found: [(String, String, Date)] = []
        for conversation in env.conversations {
            let messages = await env.store.messages(in: conversation.id, limit: 80)
            for message in messages.reversed() {
                if let inner = message.hidden.innerMonologue, !inner.isBlank {
                    let name = message.authorID.flatMap { env.persona($0)?.name } ?? conversation.title
                    found.append((name, inner, message.createdAt))
                }
                if found.count >= 20 { break }
            }
            if found.count >= 20 { break }
        }
        monologues = found
    }

    /// 把「此刻模型会看到什么」原样组装出来。这是整个潜意识层最有用的一个按钮。
    private func inspect() async {
        guard let id = selectedPersonaID, let persona = env.persona(id) else { return }
        isInspecting = true
        defer { isInspecting = false }

        let conversation = await env.store.directConversation(with: persona.id)
            ?? Conversation.direct(with: persona.id, title: persona.name)
        let history = await env.store.messages(in: conversation.id)
        let memories = await env.store.memories(stream: persona.memoryStreamID)
        let canon = await env.store.bundlesFor(persona.id)
        let edge = await env.store.edge(from: persona.id, to: nil)

        let engine = ContextEngine(embedder: ProviderHub.shared.embedder)
        let workingSet = await engine.workingSet(
            persona: persona,
            conversation: conversation,
            history: history,
            memories: memories,
            canon: canon,
            edge: edge,
            settings: env.settings,
            userInput: "（上下文透视：模拟一次普通发言）"
        )

        inspectorNotes = workingSet.notes
        inspectorText = workingSet.messages.map { message in
            let role = message.role.rawValue.uppercased()
            let images = message.images.isEmpty ? "" : " [+图 \(message.images.count)]"
            return "── \(role)\(images) ──\n\(message.content)"
        }.joined(separator: "\n\n")
            + "\n\n── 估算 ──\n约 \(workingSet.tokenEstimate) tokens"
    }
}

private struct EdgeCard: View {
    let from: String
    let to: String
    let edge: RelationshipEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(from) → \(to)").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(edge.kind.displayName)
                    .font(.system(size: 11))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: "#6C5CE7").opacity(0.14)))
                    .foregroundStyle(Color(hex: "#6C5CE7"))
            }
            meter("好感", value: (edge.affinity + 1) / 2, raw: edge.affinity)
            meter("信任", value: edge.trust, raw: edge.trust)
            meter("张力", value: edge.tension, raw: edge.tension)
            meter("熟悉", value: edge.familiarity, raw: edge.familiarity)
            if !edge.milestones.isEmpty {
                Text(edge.milestones.suffix(3).map { "· \($0.label)" }.joined(separator: "  "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func meter(_ label: String, value: Double, raw: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .tertiarySystemFill))
                    Capsule()
                        .fill(raw < 0 ? Color(hex: "#FF6B8A") : Color(hex: "#6C5CE7"))
                        .frame(width: geometry.size.width * value.clamped(0, 1))
                }
            }
            .frame(height: 5)
            Text(String(format: "%.2f", raw))
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
