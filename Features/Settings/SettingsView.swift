import AetherCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var showImporter = false
    @State private var importingPersona: Persona?
    @State private var packageBytes: Int64 = 0
    @State private var secretHold = false

    var body: some View {
        NavigationStack {
            Form {
                header

                Section("生成引擎") {
                    Picker("服务", selection: Binding(
                        get: { env.settings.providerID },
                        set: { value in Task { await env.updateSettings { $0.providerID = value } } }
                    )) {
                        Text("离线演示").tag("mock")
                        Text("OpenAI").tag("openai")
                        Text("DeepSeek").tag("deepseek")
                        Text("自建 / 兼容").tag("custom")
                    }

                    if env.settings.providerID != "mock" {
                        TextField("接口地址", text: Binding(
                            get: { env.settings.baseURL },
                            set: { value in Task { await env.updateSettings { $0.baseURL = value } } }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        HStack {
                            if showKey {
                                TextField("密钥", text: $apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("密钥", text: $apiKey)
                            }
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Button("保存密钥") {
                            Keychain.set(apiKey, for: "llm.apiKey")
                            Task { await env.updateSettings { _ in } }
                        }
                        .disabled(apiKey.isBlank)

                        TextField("对话模型", text: Binding(
                            get: { env.settings.chatModel },
                            set: { value in Task { await env.updateSettings { $0.chatModel = value } } }
                        ))
                        TextField("图像模型", text: Binding(
                            get: { env.settings.imageModel },
                            set: { value in Task { await env.updateSettings { $0.imageModel = value } } }
                        ))
                    }

                    Stepper("回复长度上限 \(env.settings.maxTokens)",
                            value: Binding(
                                get: { env.settings.maxTokens },
                                set: { value in Task { await env.updateSettings { $0.maxTokens = value } } }
                            ),
                            in: 200...4000, step: 100)
                }

                Section {
                    Slider(value: Binding(
                        get: { env.settings.performanceIntensity },
                        set: { value in Task { await env.updateSettings { $0.performanceIntensity = value } } }
                    ), in: 0...1) {
                        Text("演出强度")
                    }
                    Toggle("减少动态效果", isOn: Binding(
                        get: { env.settings.reduceMotion },
                        set: { value in Task { await env.updateSettings { $0.reduceMotion = value } } }
                    ))
                    Toggle("她会自己发照片", isOn: Binding(
                        get: { env.settings.dailyShareEnabled },
                        set: { value in Task { await env.updateSettings { $0.dailyShareEnabled = value } } }
                    ))
                } header: {
                    Text("演出")
                } footer: {
                    Text("强度调到 0 就只剩文字。调到 1 会有屏幕特效、环境音和震动。")
                }

                avatarSection

                Section("数据") {
                    HStack {
                        Text("媒体占用")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: packageBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button("备份全部数据") { Task { await exportArchive() } }
                    Button(role: .destructive) {
                        Task { await env.updateSettings { _ in } }
                    } label: { Text("清理未引用的媒体") }
                }

                Section("隐私") {
                    Toggle("记忆只存在本机", isOn: Binding(
                        get: { env.settings.localOnlyMemory },
                        set: { value in Task { await env.updateSettings { $0.localOnlyMemory = value } } }
                    ))
                    Text("密钥存在系统钥匙串，记忆存在沙盒 Documents 目录，都不上传。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("关于") {
                    HStack {
                        Text("灵犀")
                        Spacer()
                        Text("0.1.0").foregroundStyle(.secondary)
                    }
                    // 第二道暗门：长按版本号 3 秒。
                    Color.clear
                        .frame(height: 1)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 3) {
                            NotificationCenter.default.post(name: .aetherSecretTap, object: nil)
                        }
                }
            }
            .navigationTitle("我的")
            .task {
                apiKey = Keychain.get("llm.apiKey") ?? ""
                packageBytes = await MediaStore.shared.totalBytes()
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.usdz, .json, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [Color(hex: "#8A7BFF"), Color(hex: "#FFB4C8")],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(env.personas.count) 个人住在这里")
                        .font(.system(size: 16, weight: .medium))
                    Text(env.isOfflineDemo ? "当前是离线演示，接上真实模型后她们会活过来" : "已连接到生成服务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var avatarSection: some View {
        Section {
            ForEach(env.personas) { persona in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        AvatarDot(persona: persona, size: 34)
                        Text(persona.name).font(.system(size: 14, weight: .medium))
                        Spacer()
                    }

                    Picker("形象", selection: Binding(
                        get: { persona.presentation.avatarKind },
                        set: { value in
                            Task {
                                await env.store.updatePersona(persona.id) { p in
                                    p.presentation.avatarKind = value
                                }
                                await env.refresh()
                            }
                        }
                    )) {
                        ForEach(AvatarKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)

                    if let asset = persona.presentation.avatarAssetName {
                        HStack {
                            Text(asset).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    Button {
                        importingPersona = persona
                        showImporter = true
                    } label: {
                        Label(persona.presentation.avatarAssetName == nil ? "导入素材" : "换一个素材",
                              systemImage: "square.and.arrow.down")
                            .font(.system(size: 12))
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("形象与素材")
        } footer: {
            Text("""
            3D：导入 .usdz 模型（VRM 需先转成 USDZ），放到 Documents/AvatarModels/。
            2D：需要接入 Live2D Cubism SDK 才能驱动 .model3.json。
            立绘：不放素材也能用 —— 会退化成会呼吸的光核。
            """)
        }
    }

    // MARK: - 动作

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let persona = importingPersona else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let modelsDir = documents.appendingPathComponent("AvatarModels", isDirectory: true)
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            let target = modelsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                let assetName = url.deletingPathExtension().lastPathComponent
                let kind: AvatarKind = url.pathExtension.lowercased() == "usdz" ? .threeD : .live2D
                Task {
                    await env.store.updatePersona(persona.id) { p in
                        p.presentation.avatarAssetName = assetName
                        p.presentation.avatarKind = kind
                    }
                    await env.refresh()
                }
            } catch {
                Log.app.error("avatar import failed: \(error.localizedDescription)")
            }

        case .failure(let error):
            Log.app.error("import cancelled: \(error.localizedDescription)")
        }
    }

    private func exportArchive() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent("AetherBackup")
        try? FileStore().exportArchive(to: destination)
    }
}
