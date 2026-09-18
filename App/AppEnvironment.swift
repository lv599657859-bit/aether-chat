import AetherCore
import SwiftUI
import Observation

/// 全局装配。
///
/// 这是唯一一个「什么都知道」的地方 —— 它持有状态、持有引擎、持有舞台。
/// 视图层从这里拿东西，但**没有一个视图能从这里拿到模型的原始输出**：
/// 元信息全部被关在 Message.hidden 里，只有潜意识层会去读它。
@MainActor
@Observable
final class AppEnvironment {
    let store = WorldStore.shared

    var settings: AppSettings = .standard
    private(set) var personas: [Persona] = []
    private(set) var conversations: [Conversation] = []
    private(set) var isBootstrapped = false
    private(set) var lastError: String?

    let stage = StageState()
    let avatar = AvatarCoordinator()
    let autonomy: AutonomyScheduler

    private(set) var director: PerformanceDirector
    private var observerTask: Task<Void, Never>?
    private var autonomyTask: Task<Void, Never>?

    /// 离线演示模式：没配 Key 时为 true。设置页里会说明，聊天界面里绝不提示。
    var isOfflineDemo: Bool { ProviderHub.shared.llm.id == "mock" }

    init() {
        director = PerformanceDirector(stage: stage)
        autonomy = AutonomyScheduler(store: store)
    }

    // MARK: - 启动

    func bootstrap() async {
        guard !isBootstrapped else { return }
        await store.bootstrap()
        settings = await store.currentSettings()
        ProviderHub.shared.rebuild(settings: settings)
        director.configure(intensityScale: settings.performanceIntensity, reduceMotion: settings.reduceMotion)
        await refresh()
        isBootstrapped = true
        startObserving()

        // 冷启动维护：关系变淡、记忆褪色
        await ChatOrchestrator(store: store).performMaintenance()
        startAutonomy()
    }

    private func startObserving() {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.store.events() {
                if Task.isCancelled { return }
                switch event {
                case .personasChanged, .conversationsChanged:
                    await self.refresh()
                case .settingsChanged:
                    let updated = await self.store.currentSettings()
                    self.settings = updated
                    ProviderHub.shared.rebuild(settings: updated)
                    self.director.configure(
                        intensityScale: updated.performanceIntensity,
                        reduceMotion: updated.reduceMotion
                    )
                default:
                    break
                }
            }
        }
    }

    func refresh() async {
        personas = await store.allPersonas()
        conversations = await store.allConversations()
    }

    // MARK: - 自主性

    private func startAutonomy() {
        autonomyTask?.cancel()
        autonomyTask = Task { [weak self] in
            guard let self else { return }
            // 先等一会儿，别让用户刚打开 app 就被消息轰炸
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            while !Task.isCancelled {
                await self.autonomy.tick()
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 600...900) * 1_000_000_000))
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await refresh()
            await autonomy.tick()
            await refresh()
        case .background:
            autonomyTask?.cancel()
        default:
            break
        }
    }

    // MARK: - 常用动作

    /// 打开（或创建）与某个角色的单聊。
    func openConversation(with persona: Persona) async -> Conversation {
        if let existing = await store.directConversation(with: persona.id) { return existing }
        let conversation = Conversation.direct(with: persona.id, title: persona.name)
        await store.upsert(conversation)
        await store.upsert(RelationshipEdge(fromID: persona.id, toID: nil))
        await refresh()
        return conversation
    }

    func createGroup(title: String, members: [Persona]) async -> Conversation {
        let participants = members.map { Participant(personaID: $0.id, chattiness: Double.random(in: 0.3...0.8)) }
        let conversation = Conversation.group(title: title, members: participants)
        await store.upsert(conversation)
        await refresh()
        return conversation
    }

    func save(persona: Persona) async {
        await store.upsert(persona)
        await refresh()
    }

    func delete(persona: Persona) async {
        await store.deletePersona(persona.id)
        await refresh()
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) async {
        await store.updateSettings(mutate)
        settings = await store.currentSettings()
        director.configure(intensityScale: settings.performanceIntensity, reduceMotion: settings.reduceMotion)
    }

    func persona(_ id: UUID) -> Persona? { personas.first { $0.id == id } }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
}
