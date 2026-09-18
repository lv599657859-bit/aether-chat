import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: Tab = .chats
    /// 潜意识层入口：默认藏起来，连按标题 5 次才出现。
    /// 用户的要求是「不显示在明面上」，所以连入口本身都是一次仪式。
    @State private var tapCount = 0
    @State private var showSubconscious = false

    enum Tab: Hashable { case chats, contacts, me }

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                ChatListView()
                    .tabItem { Label("消息", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.chats)

                ContactListView()
                    .tabItem { Label("联系人", systemImage: "person.2") }
                    .tag(Tab.contacts)

                SettingsView()
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
                    .tag(Tab.me)
            }
            .tint(Color(hex: "#6C5CE7"))

            if !env.isBootstrapped {
                LaunchCurtain()
            }
        }
        .sheet(isPresented: $showSubconscious) {
            SubconsciousView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aetherSecretTap)) { _ in
            tapCount += 1
            if tapCount >= 5 {
                tapCount = 0
                Task {
                    let unlocked = await Vault.unlock()
                    if unlocked { showSubconscious = true }
                }
            }
        }
    }
}

extension Notification.Name {
    static let aetherSecretTap = Notification.Name("aether.secret.tap")
}

/// 启动幕布。用一句话代替加载转圈 —— 第一印象也是演出的一部分。
private struct LaunchCurtain: View {
    @State private var breathe = false

    var body: some View {
        ZStack {
            Color(hex: "#0E0B1A").ignoresSafeArea()
            VStack(spacing: 18) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "#8A7BFF").opacity(0.9), Color(hex: "#8A7BFF").opacity(0.05)],
                            center: .center, startRadius: 2, endRadius: 80
                        )
                    )
                    .frame(width: 110, height: 110)
                    .scaleEffect(breathe ? 1.08 : 0.92)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)

                Text("有人正在醒来")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                    .kerning(4)
            }
        }
        .onAppear { breathe = true }
        .transition(.opacity)
    }
}
