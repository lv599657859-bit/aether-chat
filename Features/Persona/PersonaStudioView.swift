import AetherCore
import SwiftUI

/// 创造一个人的地方。
///
/// 两条路：
///   原创 —— 手搓一份人格种子。快，但要自己想。
///   复刻 —— 输入作品名 + 角色名，它会自己去检索、整理、建库，
///           然后把一份带出处的草稿交给你审核。审核通过才浇筑。
///
/// 浇筑 = 冻结。这是唯一一次能改人格内核的机会，
/// 之后她是谁就定死了 —— 用户要的就是这个。
struct PersonaStudioView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case original, adapted }

    @State private var mode: Mode = .original

    // 原创
    @State private var name = ""
    @State private var oneLine = ""
    @State private var background = ""
    @State private var coreDesire = ""
    @State private var wound = ""
    @State private var speechStyle = ""
    @State private var stance = ""
    @State private var interests = ""
    @State private var taboos = ""

    // 复刻
    @State private var workTitle = ""
    @State private var characterName = ""
    @State private var aliases = ""
    @State private var fidelity: CanonFidelity = .faithful
    @State private var fandomSubdomain = ""
    @State private var manualText = ""
    @State private var includeEnglish = false

    // 流程
    @State private var isWorking = false
    @State private var progressLines: [String] = []
    @State private var draft: PersonaDraft?
    @State private var showReview = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $mode) {
                        Text("原创").tag(Mode.original)
                        Text("复刻").tag(Mode.adapted)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .original {
                    originalForm
                } else {
                    adaptedForm
                }

                if !progressLines.isEmpty {
                    Section("进度") {
                        ForEach(progressLines, id: \.self) { line in
                            HStack(spacing: 8) {
                                Image(systemName: "circle.dotted").font(.system(size: 10))
                                Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button {
                        Task { await commit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView().padding(.trailing, 6) }
                            Text(mode == .original ? "创造" : "开始复刻")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(isWorking || !canCommit)
                } footer: {
                    Text("人格一旦浇筑就不可更改。之后能调的只有立绘、音色、打字速度这些外在。")
                }
            }
            .navigationTitle("新的人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            }
            .sheet(isPresented: $showReview) {
                if let draft {
                    PersonaDraftReview(draft: draft) { approved in
                        Task { await forge(approved) }
                    }
                }
            }
        }
    }

    private var canCommit: Bool {
        mode == .original ? !name.isBlank : (!characterName.isBlank && !workTitle.isBlank)
    }

    // MARK: - 表单

    @ViewBuilder
    private var originalForm: some View {
        Section("她是谁") {
            TextField("名字", text: $name)
            TextField("一句话说清她是谁", text: $oneLine, axis: .vertical).lineLimit(1...3)
            TextField("她的来历", text: $background, axis: .vertical).lineLimit(2...5)
        }
        Section("她的内核") {
            TextField("她最想要什么", text: $coreDesire, axis: .vertical).lineLimit(1...3)
            TextField("她最怕什么 / 伤在哪", text: $wound, axis: .vertical).lineLimit(1...3)
        }
        Section("她怎么说话") {
            TextField("语气、句长、称呼你的方式", text: $speechStyle, axis: .vertical).lineLimit(2...5)
            TextField("她一开始怎么看你", text: $stance, axis: .vertical).lineLimit(1...3)
        }
        Section("细节") {
            TextField("会主动聊起（逗号分隔）", text: $interests, axis: .vertical).lineLimit(1...3)
            TextField("绝不会做（逗号分隔）", text: $taboos, axis: .vertical).lineLimit(1...3)
        }
    }

    @ViewBuilder
    private var adaptedForm: some View {
        Section("哪部作品里的谁") {
            TextField("作品名（如 原神）", text: $workTitle)
            TextField("角色名", text: $characterName)
            TextField("别名 / 其他译名（逗号分隔）", text: $aliases)
        }

        Section("复刻精度") {
            Picker("精度", selection: $fidelity) {
                ForEach(CanonFidelity.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Text(fidelity.enforcementLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            TextField("Fandom 子域（可选，如 genshin-impact）", text: $fandomSubdomain)
                .textInputAutocapitalization(.never)
            Toggle("同时检索英文资料", isOn: $includeEnglish)
        } header: {
            Text("来源")
        } footer: {
            Text("默认会检索萌娘百科与维基百科。填了 Fandom 子域会优先查该作品的 Wiki，通常资料最全。")
        }

        Section {
            TextField("把设定粘在这里（可选，优先级最高）", text: $manualText, axis: .vertical)
                .lineLimit(4...12)
        } header: {
            Text("手动补充")
        } footer: {
            Text("冷门角色搜不到资料时，粘贴官方设定或剧情文本，复刻质量会显著高于让它自己编。")
        }
    }

    // MARK: - 执行

    private func commit() async {
        isWorking = true
        errorText = nil
        progressLines = []

        if mode == .original {
            let seed = PersonaSeed(
                oneLine: oneLine,
                background: background,
                coreDesire: coreDesire,
                wound: wound,
                speechStyle: speechStyle,
                relationshipStance: stance,
                interests: split(interests),
                taboos: split(taboos)
            )
            var persona = PersonaFactory.forgeOriginal(name: name, seed: seed)
            persona.presentation.appearanceAnchor = "角色：\(name)。\(oneLine)。保持同一张脸、同一发型、同一配色。"
            await env.save(persona: persona)
            isWorking = false
            dismiss()
            return
        }

        let options = ResearchAgent.Options(
            workTitle: workTitle,
            characterName: characterName,
            aliases: split(aliases),
            fidelity: fidelity,
            manualText: manualText,
            fandomSubdomain: fandomSubdomain,
            includeEnglish: includeEnglish
        )

        let agent = ResearchAgent()
        let result = await agent.research(options) { line in
            Task { @MainActor in progressLines.append(line) }
        }
        draft = result
        isWorking = false
        showReview = true
    }

    private func forge(_ approved: PersonaDraft) async {
        var persona = PersonaFactory.forge(draft: approved)
        // 复刻出来的形象先用光核，用户之后可以导入立绘/3D 模型
        persona.presentation.avatarKind = .orb
        await env.save(persona: persona)
        if let bundle = approved.bundle {
            await env.store.saveBundle(bundle)
            await env.store.updatePersona(persona.id) { p in
                p.core.canonBundleID = bundle.id
                p.core.fingerprint = p.core.computeFingerprint()
            }
        }
        showReview = false
        dismiss()
    }

    private func split(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }
}

/// 复刻草稿审核。这是「准确完美」这四个字的把关点 ——
/// 所有设定、出处、拿不准的地方，全部摊开给用户看，确认了才算数。
struct PersonaDraftReview: View {
    let draft: PersonaDraft
    let onDecide: (PersonaDraft) -> Void
    @State private var edited: PersonaDraft
    @Environment(\.dismiss) private var dismiss

    init(draft: PersonaDraft, onDecide: @escaping (PersonaDraft) -> Void) {
        self.draft = draft
        self.onDecide = onDecide
        _edited = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !edited.warnings.isEmpty {
                    Section("需要注意") {
                        ForEach(edited.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("她是谁") {
                    TextField("名字", text: $edited.core.name)
                    TextField("一句话", text: $edited.core.seed.oneLine, axis: .vertical).lineLimit(1...3)
                    TextField("来历", text: $edited.core.seed.background, axis: .vertical).lineLimit(2...6)
                }

                Section("内核") {
                    TextField("最想要的", text: $edited.core.seed.coreDesire, axis: .vertical).lineLimit(1...3)
                    TextField("最怕的", text: $edited.core.seed.wound, axis: .vertical).lineLimit(1...3)
                    TextField("说话方式", text: $edited.core.seed.speechStyle, axis: .vertical).lineLimit(2...5)
                }

                Section("人格正文") {
                    TextEditor(text: $edited.core.soul)
                        .frame(minHeight: 160)
                        .font(.system(size: 13))
                }

                if let bundle = edited.bundle {
                    Section("知识库（\(bundle.facts.count) 条）") {
                        let hard = bundle.hardFacts
                        if !hard.isEmpty {
                            DisclosureGroup("铁律 \(hard.count) 条") {
                                ForEach(hard) { fact in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fact.body).font(.system(size: 12))
                                        Text(fact.citation).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        DisclosureGroup("全部设定") {
                            ForEach(bundle.facts.prefix(40)) { fact in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(fact.category.displayName)] \(fact.body)")
                                        .font(.system(size: 12))
                                }
                            }
                        }
                        if !bundle.speechCorpus.isEmpty {
                            DisclosureGroup("台词样本 \(bundle.speechCorpus.count) 条") {
                                ForEach(bundle.speechCorpus.prefix(10), id: \.self) { line in
                                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !edited.openQuestions.isEmpty {
                    Section("资料里没写清楚的") {
                        ForEach(edited.openQuestions, id: \.self) { question in
                            Text("· \(question)").font(.footnote)
                        }
                    }
                }

                Section {
                    Button {
                        onDecide(edited)
                    } label: {
                        HStack {
                            Spacer()
                            Text("就这样，浇筑她").font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    Button("回去改改") { dismiss() }
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("浇筑后人格内核不可再改。不满意的部分，现在改。")
                }
            }
            .navigationTitle("审核")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 建群。
struct GroupCreateView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, [Persona]) -> Void

    @State private var title = ""
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("群名") {
                    TextField("给这个群起个名字", text: $title)
                }
                Section("拉谁进来（至少两个）") {
                    ForEach(env.personas) { persona in
                        Button {
                            if selected.contains(persona.id) { selected.remove(persona.id) }
                            else { selected.insert(persona.id) }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarDot(persona: persona, size: 36)
                                Text(persona.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(persona.id) {
                                    Image(systemName: "checkmark").foregroundStyle(Color(hex: "#6C5CE7"))
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("建好之后，他们会自己找话说。你不说话的时候，他们之间也会发生事。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("建个群")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
                        let members = env.personas.filter { selected.contains($0.id) }
                        onCreate(title.isBlank ? "群聊" : title, members)
                    }
                    .disabled(selected.count < 2)
                }
            }
        }
    }
}
