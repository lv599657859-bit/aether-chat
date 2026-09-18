import SwiftUI

struct ContactListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showStudio = false
    @State private var showSearch = false
    @State private var selected: Persona?
    @State private var path: [Persona] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if env.personas.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                        Text("还没有人")
                            .font(.headline)
                        Text("捏一个原创角色，或者从作品里复刻一个人。\n复刻会自动检索资料并建立她的知识库。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button { showSearch = true } label: {
                            Label("搜一个角色", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#6C5CE7"))

                        Button("原创一个") { showStudio = true }
                    }
                    .padding()
                } else {
                    List {
                        ForEach(env.personas) { persona in
                            NavigationLink(value: persona) {
                                PersonaRow(persona: persona)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await env.delete(persona: persona) }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("联系人")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showSearch = true } label: {
                            Label("搜一个角色", systemImage: "magnifyingglass")
                        }
                        Button { showStudio = true } label: {
                            Label("原创一个", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: Persona.self) { persona in
                PersonaDetailView(persona: persona)
            }
            .sheet(isPresented: $showStudio) { PersonaStudioView() }
            .sheet(isPresented: $showSearch) { CharacterSearchView() }
        }
    }
}

private struct PersonaRow: View {
    @Environment(AppEnvironment.self) private var env
    let persona: Persona
    @State private var kindLabel: String = ""

    var body: some View {
        HStack(spacing: 12) {
            AvatarDot(persona: persona, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(persona.name).font(.system(size: 16, weight: .medium))
                    if persona.isFrozen {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(persona.core.seed.oneLine.isEmpty ? persona.core.soul.prefix(30).description : persona.core.seed.oneLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if persona.hasCanon {
                    Text(persona.fidelity.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: "#6C5CE7").opacity(0.14)))
                        .foregroundStyle(Color(hex: "#6C5CE7"))
                }
                Text(kindLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let edge = await env.store.edge(from: persona.id, to: nil)
            kindLabel = edge.kind.displayName
        }
    }
}

/// 角色详情。这里展示的是「她是谁」，而不是「她怎么被实现的」。
struct PersonaDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let persona: Persona
    @State private var showCanon = false
    @State private var showVoice = false
    @State private var showRelationship = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        AvatarDot(persona: persona, size: 84)
                        Text(persona.name).font(.system(size: 20, weight: .semibold))
                        Text(persona.core.seed.oneLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("关于她") {
                detailRow("来历", persona.core.seed.background)
                detailRow("想要的", persona.core.seed.coreDesire)
                detailRow("怕的", persona.core.seed.wound)
                detailRow("说话方式", persona.core.seed.speechStyle)
                if !persona.core.speechQuirks.isEmpty {
                    detailRow("口癖", persona.core.speechQuirks.joined(separator: "、"))
                }
                if !persona.core.seed.interests.isEmpty {
                    detailRow("会聊起", persona.core.seed.interests.joined(separator: "、"))
                }
            }

            Section("人格状态") {
                HStack {
                    Label("已验证未被改动", systemImage: persona.core.isIntact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(persona.core.isIntact ? .green : .orange)
                    Spacer()
                    Text("v\(persona.core.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let frozenAt = persona.core.frozenAt {
                    detailRow("固化于", frozenAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button("查看固化印记（\(persona.seals.count)）") { showCanon = true }
            }

            if persona.hasCanon {
                Section("复刻") {
                    detailRow("出处", persona.core.sourceWork ?? "—")
                    detailRow("精度", persona.fidelity.displayName)
                    Button("查看她的知识库") { showCanon = true }
                }
            }

            Section {
                Button {
                    showVoice = true
                } label: {
                    HStack {
                        Label("配音与调音", systemImage: "waveform")
                        Spacer()
                        Text(persona.presentation.voice.systemVoiceID.flatMap { VoiceCatalog.entry(for: $0)?.name } ?? "未指定")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("「\(VoiceDesigner.sampleLine(for: persona))」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("声音")
            } footer: {
                Text("调音色、语速、音高，不影响人格。")
            }

            Section {
                Button("调整外在（不影响人格）") { showCanon = true }
                Button(role: .destructive) {
                    Task { await env.delete(persona: persona) }
                } label: { Text("让她离开") }
            }
        }
        .navigationTitle(persona.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showVoice) {
            VoiceStudioView(persona: persona)
        }
        .sheet(isPresented: $showCanon) {
            CanonViewer(persona: persona)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.system(size: 14))
        }
    }
}

/// 知识库查看器。用户要求复刻要「准确完美」，那就必须让他能核对每一条出处。
struct CanonViewer: View {
    @Environment(AppEnvironment.self) private var env
    let persona: Persona
    @State private var bundle: CanonBundle?
    @State private var selectedCategory: CanonFact.Category?

    var filtered: [CanonFact] {
        guard let bundle else { return [] }
        guard let selectedCategory else { return bundle.facts }
        return bundle.facts(in: selectedCategory)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let bundle {
                    List {
                        Section {
                            HStack {
                                Text("\(bundle.facts.count) 条设定")
                                Spacer()
                                Text("指纹 \(bundle.fingerprint.prefix(8))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("分类") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    categoryChip(nil, "全部")
                                    ForEach(CanonFact.Category.allCases, id: \.self) { category in
                                        if !bundle.facts(in: category).isEmpty {
                                            categoryChip(category, category.displayName)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        ForEach(filtered) { fact in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    if fact.isHard {
                                        Image(systemName: "lock.shield.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color(hex: "#6C5CE7"))
                                    }
                                    Text(fact.title).font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    Text(String(format: "%.0f%%", fact.confidence * 100))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Text(fact.body).font(.system(size: 13)).foregroundStyle(.secondary)
                                if let source = fact.sources.first, source.url.hasPrefix("http") {
                                    Link(destination: URL(string: source.url)!) {
                                        Text("出自 \(source.kind.displayName)：\(source.title)")
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    ContentUnavailableView("没有知识库", systemImage: "books.vertical",
                                           description: Text("这个角色是原创的，或者复刻时没有抓取到资料。"))
                }
            }
            .navigationTitle("知识库")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { bundle = await env.store.bundlesFor(persona.id) }
    }

    private func categoryChip(_ category: CanonFact.Category?, _ title: String) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(
                    selectedCategory == category
                        ? Color(hex: "#6C5CE7").opacity(0.2)
                        : Color(uiColor: .tertiarySystemFill)
                ))
                .foregroundStyle(selectedCategory == category ? Color(hex: "#6C5CE7") : .primary)
        }
    }
}
