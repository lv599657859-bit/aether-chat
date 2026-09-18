import SwiftUI

/// 搜一个角色 —— 建立角色卡的主入口。
///
/// 之前的复刻流程埋在「联系人 → + → 选复刻 → 填表 → 跑」四层里，
/// 这个页面把「搜索」提到第一屏：输名字、搜、看一眼、建卡。
struct CharacterSearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var characterName = ""
    @State private var workTitle = ""
    @State private var aliases = ""
    @State private var fidelity: CanonFidelity = .faithful
    @State private var fandomSubdomain = ""
    @State private var isSearching = false
    @State private var progressLines: [String] = []
    @State private var draft: PersonaDraft?
    @State private var showReview = false
    @State private var isForging = false

    private var canSearch: Bool { !characterName.isBlank }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("角色名（必填）", text: $characterName)
                        .textInputAutocapitalization(.never)
                    TextField("出自哪部作品（建议填）", text: $workTitle)
                    TextField("别名 / 其他译名（逗号分隔）", text: $aliases)
                } header: {
                    Text("搜谁")
                } footer: {
                    Text("会去萌娘百科、维基百科、Fandom 检索她的公开设定，抽事实、标置信度、检测冲突，然后给你一份带出处的档案。")
                }

                Section("复刻精度") {
                    Picker("精度", selection: $fidelity) {
                        ForEach(CanonFidelity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text(fidelity.enforcementLine)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextField("Fandom 子域（可选，如 genshin-impact）", text: $fandomSubdomain)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("填了会优先查该作品的 Fandom Wiki，通常资料最全。")
                }

                if !progressLines.isEmpty {
                    Section("检索进度") {
                        ForEach(progressLines, id: \.self) { line in
                            HStack(spacing: 8) {
                                Image(systemName: "circle.dotted").font(.system(size: 10))
                                Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSearching { ProgressView().padding(.trailing, 6) }
                            Text(isSearching ? "正在检索…" : "搜索并生成角色卡")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(isSearching || !canSearch)
                }

                if env.isOfflineDemo {
                    Section {
                        Label("当前没有配置生成服务，抽取质量会明显下降", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Text("检索本身不需要密钥，但把资料整理成设定需要模型。没有模型时会退化成关键词抽取 —— 能用，但粗糙。想要准确复刻，先去「我的 → 生成引擎」配一个服务。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("搜一个角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            }
            .sheet(isPresented: $showReview) {
                if let draft {
                    PersonaDraftReview(draft: draft, onDecide: { approved in
                        Task { await forge(approved) }
                    })
                }
            }
        }
    }

    private func search() async {
        isSearching = true
        progressLines = []
        defer { isSearching = false }

        let options = ResearchAgent.Options(
            workTitle: workTitle.isBlank ? "未知作品" : workTitle,
            characterName: characterName.trimmed,
            aliases: aliases.split(whereSeparator: { ",，、;；".contains($0) })
                .map { String($0).trimmed }.filter { !$0.isEmpty },
            fidelity: fidelity,
            manualText: "",
            fandomSubdomain: fandomSubdomain.trimmed,
            includeEnglish: false
        )

        let result = await ResearchAgent().research(options) { line in
            Task { @MainActor in progressLines.append(line) }
        }
        draft = result
        showReview = true
    }

    private func forge(_ approved: PersonaDraft) async {
        isForging = true
        defer { isForging = false }

        var persona = PersonaFactory.forge(draft: approved)
        persona.presentation.avatarKind = .orb

        // 铸完立刻配一副嗓子 —— 「自动生成角色语音」从这里接上
        let design = await VoiceDesigner().design(for: persona)
        persona.presentation.voice = VoiceDesigner().resolve(design)

        await env.save(persona: persona)

        if let bundle = approved.bundle {
            await env.store.saveBundle(bundle)
            await env.store.updatePersona(persona.id) { p in
                p.core.canonBundleID = bundle.id
                p.core.fingerprint = p.core.computeFingerprint()
            }
        }
        await env.refresh()
        showReview = false
        dismiss()
    }
}
