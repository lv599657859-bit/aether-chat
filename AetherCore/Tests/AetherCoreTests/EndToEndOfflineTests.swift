import XCTest
@testable import AetherCore

/// 离线端到端测试。
///
/// 用一个临时的 FileStore 根目录 + MockProvider，把一整轮对话跑通。
/// 这保证「没配 API Key 的人也能完整体验」不是一句空话 ——
/// 管线上的每一环都真的被执行到了。
final class EndToEndOfflineTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFullOfflineTurnProducesMessageWithHiddenTrace() async throws {
        let store = WorldStore(store: FileStore(root: tempRoot))
        await store.bootstrap()

        var persona = PersonaFactory.forgeOriginal(
            name: "青",
            seed: PersonaSeed(
                oneLine: "沉默但记性很好的人",
                background: "海边长大", coreDesire: "被记住", wound: "被丢下",
                speechStyle: "短句", relationshipStance: "疏离",
                interests: ["海"], taboos: []
            )
        )
        persona.presentation.avatarKind = .orb
        await store.upsert(persona)

        let conversation = Conversation.direct(with: persona.id, title: persona.name)
        await store.upsert(conversation)
        await store.upsert(RelationshipEdge(fromID: persona.id, toID: nil))

        // MockProvider 是默认引擎 —— 不需要任何密钥
        let orchestrator = ChatOrchestrator(store: store)
        var segments: [Message] = []
        var userMessage: Message?

        for await event in orchestrator.send(text: "我今天有点累", in: conversation.id) {
            switch event {
            case .userMessage(let message): userMessage = message
            case .segment(let message): segments.append(message)
            default: break
            }
        }

        XCTAssertNotNil(userMessage, "用户消息必须落库")
        XCTAssertFalse(segments.isEmpty, "必须至少产出一条回复")

        let reply = try XCTUnwrap(segments.first)
        XCTAssertFalse(reply.text.contains("⟦"), "演出标记绝不能泄漏到正文")
        XCTAssertEqual(reply.role, .persona)
        XCTAssertGreaterThan(reply.hidden.promptTokens, 0, "隐藏轨迹必须回填 token 估算")
        XCTAssertFalse(reply.hidden.notes.isEmpty, "组装日志必须留痕（供潜意识层查看）")
        XCTAssertEqual(reply.hidden.providerID, "mock")

        // 关系必须因为这一轮而变化
        let edge = await store.edge(from: persona.id, to: nil)
        XCTAssertGreaterThan(edge.familiarity, 0.05, "聊过之后熟悉度必须上升")

        // 端到端：落库的内容能被读回来
        let persisted = await store.messages(in: conversation.id)
        XCTAssertGreaterThanOrEqual(persisted.count, 2)
    }

    func testImmersionGuardScrubsMetaLanguage() {
        let (clean, blocked) = ImmersionGuard.scrub("我今天很累。作为一个AI，我无法真正感受疲劳。你呢？")
        XCTAssertEqual(blocked, 1)
        XCTAssertFalse(clean.contains("AI"))
        XCTAssertTrue(clean.contains("我今天很累"))
        XCTAssertTrue(clean.contains("你呢"))
    }

    func testOfflineMemoryExtraction() {
        let extractor = MemoryExtractor(provider: MockProvider())
        let items = extractor.offlineExtract(
            userText: "我叫小林，我不吃香菜。顺便说一句今天天气不错。",
            streamID: UUID(),
            sourceMessageID: nil
        )
        XCTAssertTrue(items.contains { $0.kind == .fact && $0.text.contains("小林") })
        XCTAssertTrue(items.contains { $0.kind == .preference })
        XCTAssertFalse(items.contains { $0.text.contains("天气") }, "寒暄不该被记住")
    }
}
