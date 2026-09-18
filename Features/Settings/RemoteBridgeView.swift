import SwiftUI

/// 电脑桥接的配对页。
///
/// 这一页是方案 C 的全部界面：填地址、填令牌、选你愿意让它碰什么。
/// 手机上的代理因此多出六个工具，而 app 本身没有变大一点。
struct RemoteBridgeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var config = RemoteBridgeStore.load()
    @State private var token = RemoteBridgeStore.token
    @State private var status: BridgeStatus?
    @State private var testing = false
    @State private var message: String?
    @State private var isError = false
    @State private var confirmDangerous: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用电脑桥接", isOn: $config.enabled)
                } footer: {
                    Text("打开后，手机上的代理可以把任务交给电脑上运行的完整 DSH —— 那边有联网、文件、命令、子代理和技能。关掉它，这些工具会立刻失效。")
                }

                Section("电脑地址") {
                    TextField("主机（如 172.16.0.10）", text: $config.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("8787", value: $config.port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 90)
                    }
                    Text("地址和端口在电脑启动桥接时会打印出来。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("配对令牌") {
                    SecureField("粘贴电脑上打印的令牌", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || config.host.isBlank || token.isBlank)

                    if let message {
                        Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .green)
                    }
                    if let status {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已连上 \(status.name) v\(status.version)")
                                .font(.system(size: 13, weight: .medium))
                            Text("电脑：\(status.host)（\(status.platform)）")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("电脑端开放了：\(status.capabilities.joined(separator: "、"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("连接")
                }

                Section {
                    ForEach(RemoteBridgeConfig.allCapabilities, id: \.self) { capability in
                        Toggle(isOn: Binding(
                            get: { config.capabilities.contains(capability) },
                            set: { on in
                                if on && RemoteBridgeConfig.isDangerous(capability) {
                                    confirmDangerous = capability
                                } else if on {
                                    config.capabilities.insert(capability)
                                    RemoteBridgeStore.save(config)
                                } else {
                                    config.capabilities.remove(capability)
                                    RemoteBridgeStore.save(config)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RemoteBridgeConfig.displayName(for: capability))
                                    .font(.system(size: 14))
                                if RemoteBridgeConfig.isDangerous(capability) {
                                    Text("危险：任何拿到你手机的人都能用它操作你的电脑")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("允许它碰什么")
                } footer: {
                    Text("这里是第二道闸。电脑端的 --allow 是第一道。两道都开，才真的能通。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("在电脑上运行：").font(.caption).foregroundStyle(.secondary)
                        Text("node Tools/dsh-bridge.mjs")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Text("要开放跑命令和写文件，加参数：")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text("node Tools/dsh-bridge.mjs --allow ask,read,ls,exec,write")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("手机和电脑要在同一个 Wi-Fi 下。")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                } header: {
                    Text("怎么启动")
                }
            }
            .navigationTitle("电脑桥接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        RemoteBridgeStore.save(config)
                        RemoteBridgeStore.token = token
                        dismiss()
                    }.bold()
                }
            }
            .alert("确认打开？", isPresented: Binding(
                get: { confirmDangerous != nil },
                set: { if !$0 { confirmDangerous = nil } }
            )) {
                Button("取消", role: .cancel) { confirmDangerous = nil }
                Button("我明白", role: .destructive) {
                    if let capability = confirmDangerous {
                        config.capabilities.insert(capability)
                        RemoteBridgeStore.save(config)
                    }
                    confirmDangerous = nil
                }
            } message: {
                Text(confirmDangerous.map { RemoteBridgeConfig.displayName(for: $0) } ?? "")
            }
        }
    }

    private func test() async {
        testing = true
        message = nil
        status = nil
        RemoteBridgeStore.save(config)
        RemoteBridgeStore.token = token
        do {
            let result = try await DSHBridgeClient.shared.status()
            status = result
            message = "通了"
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
        testing = false
    }
}
