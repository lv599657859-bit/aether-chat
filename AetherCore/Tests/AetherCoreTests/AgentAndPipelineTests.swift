import XCTest
@testable import AetherCore

/// 代理运行时与流水线的测试。
///
/// 这两个是这一轮新加的地基：代理决定「她能不能自己干活」，
/// 流水线决定「她要不要回这一句」。地基歪了，上面盖什么都白搭。
final class AgentAndPipelineTests: XCTestCase {

    // MARK: - 工具调用解析

    func testParseThinkAndToolCall() {
        let raw = """
        ⟦think:先查一下她的设定⟧
        ⟦tool:web_search⟧{"query":"钟离 原神 设定"}
        """
        let parsed = AgentRuntime.parse(raw)
        XCTAssertEqual(parsed.thought, "先查一下她的设定")
        XCTAssertEqual(parsed.toolCall?.name, "web_search")
        XCTAssertEqual(parsed.toolCall?.arguments["query"], "钟离 原神 设定")
    }

    func testParseReturnsNoToolCallForPlainAnswer() {
        let parsed = AgentRuntime.parse("查到了，钟离是往生堂的客卿。")
        XCTAssertNil(parsed.toolCall)
        XCTAssertNil(parsed.thought)
    }

    /// 参数多行时只取工具行本身，不要吞掉后面的正文。
    func testToolCallArgumentsStopAtLineEnd() {
        let raw = """
        ⟦tool:fetch_page⟧{"url":"https://example.com/a"}
        这段是解释，不该被当成参数。
        """
        let parsed = AgentRuntime.parse(raw)
        XCTAssertEqual(parsed.toolCall?.arguments["url"], "https://example.com/a")
        XCTAssertEqual(parsed.toolCall?.arguments.count, 1)
    }

    func testParseArgumentsAcceptsJSON() {
        let args = AgentRuntime.parseArguments(#"{"a":"1","b":2,"c":["x","y"]}"#)
        XCTAssertEqual(args["a"], "1")
        XCTAssertEqual(args["b"], "2")
        XCTAssertEqual(args["c"], "x,y")
    }

    /// 模型不总是老实写 JSON，key=value 也得认。
    func testParseArgumentsAcceptsLooseForm() {
        let args = AgentRuntime.parseArguments("name=青, work=原神")
        XCTAssertEqual(args["name"], "青")
        XCTAssertEqual(args["work"], "原神")
    }

    func testParseArgumentsEmpty() {
        XCTAssertTrue(AgentRuntime.parseArguments("").isEmpty)
    }

    // MARK: - 工具注册表

    func testRegistryRegistersAndBriefs() {
        let registry = ToolRegistry()
        registry.register(WebSearchTool())
        XCTAssertNotNil(registry.tool(named: "web_search"))
        XCTAssertNil(registry.tool(named: "不存在的工具"))
        XCTAssertTrue(registry.briefing.contains("web_search"))
        XCTAssertTrue(registry.briefing.contains("query"))
    }

    func testBuiltinRegistryHasCoreTools() {
        let names = ToolRegistry.builtin.all.map { $0.name }
        for expected in ["web_search", "fetch_page", "research_character",
                         "create_character", "list_characters", "recall_memory", "remember"] {
            XCTAssertTrue(names.contains(expected), "缺少内置工具 \(expected)")
        }
        // 依赖 AVFoundation 的工具不该在内核里 —— 它由外壳注册
        XCTAssertFalse(names.contains("design_voice"))
    }

    // MARK: - 流水线

    private struct VetoStage: ReplyStage {
        let name = "测试拦截"
        let order = 5
        func process(_ context: inout ReplyContext) async -> PipelineDecision {
            .stop("测试用")
        }
    }

    private struct AddStage: ReplyStage {
        let name = "测试追加"
        let order = 15
        func process(_ context: inout ReplyContext) async -> PipelineDecision {
            .annotate("追加的一句")
        }
    }

    private func makePersona() -> Persona {
        PersonaFactory.forgeOriginal(
            name: "青",
            seed: PersonaSeed(
                oneLine: "沉默的人", background: "", coreDesire: "", wound: "",
                speechStyle: "短句", relationshipStance: "",
                interests: ["海"], taboos: []
            )
        )
    }

    private func makeStore() throws -> (WorldStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WorldStore(store: FileStore(root: root)), root)
    }

    func testPipelineStopsOnVeto() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = ReplyPipeline()
        pipeline.add(AddStage())
        pipeline.add(VetoStage())

        var context = ReplyContext(
            conversationID: UUID(), persona: makePersona(),
            incomingText: "随便", store: store
        )
        context = await pipeline.run(context)
        XCTAssertFalse(context.shouldReply)
        XCTAssertEqual(context.suppressReason, "测试用")
        // 排在拦截之后的环节不该再执行
        XCTAssertTrue(context.injections.isEmpty)
    }

    func testPipelineCollectsAnnotations() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = ReplyPipeline()
        pipeline.add(AddStage())

        var context = ReplyContext(
            conversationID: UUID(), persona: makePersona(),
            incomingText: "随便", store: store
        )
        context = await pipeline.run(context)
        XCTAssertTrue(context.shouldReply)
        XCTAssertEqual(context.injections, ["追加的一句"])
        XCTAssertTrue(context.trace.contains { $0.contains("测试追加") })
    }

    func testPipelineRunsStagesInOrder() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = ReplyPipeline()
        pipeline.add(AddStage())      // order 15
        pipeline.add(VetoStage())     // order 5
        XCTAssertEqual(pipeline.stageNames, ["测试拦截", "测试追加"])

        var context = ReplyContext(
            conversationID: UUID(), persona: makePersona(),
            incomingText: "随便", store: store
        )
        context = await pipeline.run(context)
        // 5 在 15 前面，所以拦截先生效
        XCTAssertFalse(context.shouldReply)
    }

    // MARK: - 兴趣度

    /// 群聊里，一句没有指向性的短话应该被拦下 —— 「从不冷场」才是最不像人的地方。
    func testInterestSuppressesLowSignalInGroup() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var context = ReplyContext(
            conversationID: UUID(), persona: makePersona(),
            incomingText: "嗯", isGroup: true, store: store
        )
        let decision = await InterestStage().process(&context)
        if case .stop = decision {
            XCTAssertLessThan(context.interest, 0.45)
        } else {
            XCTFail("低信号消息在群里应该被拦下，实际兴趣度 \(context.interest)")
        }
    }

    /// 被叫名字是最强信号，群里也必须接。
    func testInterestRespondsWhenNamed() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var context = ReplyContext(
            conversationID: UUID(), persona: makePersona(),
            incomingText: "青，你怎么看", isGroup: true, store: store
        )
        let decision = await InterestStage().process(&context)
        if case .stop = decision {
            XCTFail("被点名了还不接，实际兴趣度 \(context.interest)")
        }
        XCTAssertGreaterThan(context.interest, 0.45)
    }

    /// 私聊门槛低得多 —— 一对一的时候，她大多时候应该回。
    func testInterestUsuallyProceedsInDirectMessage() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var context = ReplyContext(
            conversationID: UUID(), persona: makePersona(),
            incomingText: "今天外面下雨了", store: store
        )
        let decision = await InterestStage().process(&context)
        if case .stop = decision {
            XCTFail("私聊里普通一句话不该被拦，实际兴趣度 \(context.interest)")
        }
    }

    // MARK: - 表达学习

    func testExpressionCandidatesFindAddressPatterns() {
        let candidates = ExpressionLearner.candidates(from: "老张说这个不错，小林哥也这么觉得")
        let addresses = candidates.filter { $0.kind == .address }.map { $0.text }
        XCTAssertTrue(addresses.contains { $0.contains("老") || $0.contains("哥") },
                      "应该抓到称呼模式，实际：\(addresses)")
    }

    func testExpressionCandidatesIgnoreSingleCharacter() {
        XCTAssertTrue(ExpressionLearner.candidates(from: "。").isEmpty)
    }

    /// 出现次数不够的说法不该被注入 —— 学一次就开始学舌很假。
    func testOnlyAdoptedExpressionsAreInjected() async {
        let learner = ExpressionLearner()
        // 注意：必须用 persona.id 去 observe。用另一个 UUID 的话，
        // 统计落在一条没人查的账上，测试会永远失败 —— 这个坑我踩过一次。
        let persona = PersonaFactory.forgeOriginal(name: "测试用-\(UUID().uuidString.prefix(8))", seed: .empty)

        await learner.observe(userText: "绝了", personaID: persona.id)
        let briefingAfterOne = await learner.briefing(for: persona)
        XCTAssertNil(briefingAfterOne, "只说了一次就学会，太急了")

        for _ in 0..<3 {
            await learner.observe(userText: "绝了", personaID: persona.id)
        }
        let briefingAfterFour = await learner.briefing(for: persona)
        XCTAssertNotNil(briefingAfterFour)
        XCTAssertTrue(briefingAfterFour?.contains("绝了") ?? false)
    }

    /// 学到的说法要真的被用起来才算学会 —— noteUsed 记账。
    func testNoteUsedMarksExpressionAsUsed() async {
        let learner = ExpressionLearner()
        let persona = PersonaFactory.forgeOriginal(name: "测试用-\(UUID().uuidString.prefix(8))", seed: .empty)
        for _ in 0..<3 {
            await learner.observe(userText: "破防了", personaID: persona.id)
        }
        await learner.noteUsed(personaID: persona.id, text: "我也有点破防了")
        let adopted = await learner.adopted(for: persona.id)
        XCTAssertTrue(adopted.contains { $0.usedByPersona > 0 }, "用了却没记账")
    }

    func testForgetRemovesExpression() async {
        let learner = ExpressionLearner()
        let persona = PersonaFactory.forgeOriginal(name: "测试用-\(UUID().uuidString.prefix(8))", seed: .empty)
        for _ in 0..<3 {
            await learner.observe(userText: "好家伙", personaID: persona.id)
        }
        // 注意：xctest 的断言参数是自动闭包，里面不能写 await —— 先取值再断言。
        let before = await learner.briefing(for: persona)
        XCTAssertNotNil(before, "重复三次之后应该已经学会了")
        await learner.clear(personaID: persona.id)
        let after = await learner.briefing(for: persona)
        XCTAssertNil(after, "清空之后不该再注入")
    }
}
