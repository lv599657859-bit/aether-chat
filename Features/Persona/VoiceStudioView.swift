import SwiftUI
import AVFoundation

/// 声音工作室 —— 角色的嗓子在这里定。
///
/// 之前的问题是：VoiceProfile 这个结构存在，但界面层一次都没引用过，
/// 等于「能说话但没有配声音的地方」。这个页面补上那一段。
struct VoiceStudioView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let persona: Persona

    @State private var profile: VoiceProfile
    @State private var voices: [VoiceCatalog.Entry] = []
    @State private var scope: Scope = .chinese
    @State private var designerNote: String = ""
    @State private var isDesigning = false
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>?

    private let synthesizer = SystemSpeechSynthesizer()

    enum Scope: String, CaseIterable {
        case chinese, all
        var title: String { self == .chinese ? "中文" : "全部语言" }
    }

    init(persona: Persona) {
        self.persona = persona
        _profile = State(initialValue: persona.presentation.voice)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await autoDesign() }
                    } label: {
                        HStack {
                            Label("自动配一个声音", systemImage: "wand.and.stars")
                            Spacer()
                            if isDesigning { ProgressView() }
                        }
                    }
                    .disabled(isDesigning)
                    if !designerNote.isEmpty {
                        Text(designerNote).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("从她的人格推导")
                } footer: {
                    Text("读她的说话方式、性格和口癖，推出音高、语速和音色描述，再落到一个具体音色上。")
                }

                Section("音色") {
                    Picker("范围", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented)
                        .onChange(of: scope) { _, _ in reloadVoices() }

                    Picker("音色", selection: Binding(
                        get: { profile.systemVoiceID ?? "" },
                        set: { profile.systemVoiceID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("未指定").tag("")
                        ForEach(voices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    sliderRow("语速", value: $profile.rate, range: 0.2...0.8)
                    sliderRow("音高", value: $profile.pitch, range: 0.6...1.5)
                    sliderRow("音量", value: $profile.volume, range: 0.2...1.0)
                } header: {
                    Text("调音")
                } footer: {
                    Text("语速 0.38 左右是慢条斯理，0.6 以上是话赶话。音高 0.86 偏低沉，1.16 偏清亮。")
                }

                Section {
                    TextEditor(text: $profile.timbrePrompt)
                        .frame(minHeight: 80)
                        .font(.system(size: 13))
                } header: {
                    Text("音色描述")
                } footer: {
                    Text("这一栏是给云端语音合成用的。系统音色用不到它；接上支持音色描述的服务后，这段文字决定她听起来像谁。")
                }

                Section {
                    Button {
                        togglePreview()
                    } label: {
                        Label(isPreviewing ? "停止" : "试听这句", systemImage: isPreviewing ? "stop.fill" : "play.fill")
                    }
                    Text("「\(VoiceDesigner.sampleLine(for: persona))」")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("试听")
                }
            }
            .navigationTitle("\(persona.name) 的声音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await save() } }.bold()
                }
            }
            .task { reloadVoices() }
            .onDisappear {
                previewTask?.cancel()
                synthesizer.stop()
            }
        }
    }

    private func sliderRow(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { _ in }
        }
    }

    private func reloadVoices() {
        voices = scope == .chinese ? VoiceCatalog.chinese() : VoiceCatalog.all()
    }

    @MainActor
    private func autoDesign() async {
        isDesigning = true
        defer { isDesigning = false }
        let design = await VoiceDesigner().design(for: persona)
        let resolved = VoiceDesigner().resolve(design)
        profile.systemVoiceID = resolved.systemVoiceID
        profile.rate = resolved.rate
        profile.pitch = resolved.pitch
        profile.timbrePrompt = resolved.timbrePrompt
        designerNote = design.note + (VoiceCatalog.entry(for: resolved.systemVoiceID).map { "，选中「\($0.name)」" } ?? "")
        reloadVoices()
    }

    private func togglePreview() {
        if isPreviewing {
            previewTask?.cancel()
            synthesizer.stop()
            isPreviewing = false
            return
        }
        isPreviewing = true
        let line = VoiceDesigner.sampleLine(for: persona)
        let snapshot = profile
        previewTask = Task {
            do {
                for try await event in synthesizer.speak(line, profile: snapshot) {
                    if case .finished = event { break }
                }
            } catch {
                Log.voice.error("preview failed: \(error.localizedDescription)")
            }
            await MainActor.run { isPreviewing = false }
        }
    }

    private func save() async {
        synthesizer.stop()
        await env.store.updatePersona(persona.id) { p in
            p.presentation.voice = profile
        }
        await env.refresh()
        dismiss()
    }
}
