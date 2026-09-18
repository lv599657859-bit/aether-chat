import XCTest
@testable import AetherCore

/// 上下文引擎测试。
/// 用户要求「能自行解决上下文问题，但并不显示在明面上」——
/// 那它就必须真的能解决问题，而不是假装在解决。
final class ContextEngineTests: XCTestCase {

    private func makePersona() -> Persona {
        PersonaFactory.forgeOriginal(
            name: "青",
            seed: PersonaSeed(
                oneLine: "沉默但记性很好的人",
                background: "海边长大",
                coreDesire: "被记住",
                wound: "被丢下",
                speechStyle: "短句",
                relationshipStance: "疏离",
                interests: ["海"],
                taboos: []
            )
        )
    }

    func testSystemPromptAlwaysAnchorsPersona() async {
        let persona = makePersona()
        let conversation = Conversation.direct(with: persona.id, title: persona.name)
        let engine = ContextEngine(embedder: HashingEmbedder())

        let ws = await engine.workingSet(
            persona: persona,
            conversation: conversation,
            history: [],
            memories: [],
            canon: nil,
            edge: RelationshipEdge(fromID: persona.id, toID: nil),
            settings: .standard,
            userInput: "在吗"
        )

        XCTAssertTrue(ws.systemPrompt.contains(persona.name), "人格必须每轮重新锚定")
        XCTAssertTrue(ws.systemPrompt.contains("演出协议"))
        XCTAssertTrue(ws.systemPrompt.contains("绝对禁令"), "沉浸守门必须默认开启")
    }

    func testRelevantMemoryOutranksIrrelevant() async {
        let embedder = HashingEmbedder()
        let stream = UUID()
        let relevant = MemoryItem(streamID: stream, kind: .preference, text: "我不吃香菜", salience: 0.6)
        let noise = MemoryItem(streamID: stream, kind: .fact, text: "今天股市大涨", salience: 0.6)

        let vectors = (try? await embedder.embed([relevant.text, noise.text])) ?? []
        var a = relevant
        a.embedding = vectors.first ?? []
        var b = noise
        b.embedding = vectors.count > 1 ? vectors[1] : []

        let persona = makePersona()
        let engine = ContextEngine(embedder: embedder, budget: .compact)
        let ws = await engine.workingSet(
            persona: persona,
            conversation: .direct(with: persona.id, title: "青"),
            history: [],
            memories: [a, b],
            canon: nil,
            edge: RelationshipEdge(fromID: persona.id, toID: nil),
            settings: .standard,
            userInput: "晚上吃什么好，我不太想吃香菜"
        )

        XCTAssertTrue(ws.recalledMemories.contains { $0.id == a.id })
        XCTAssertTrue(ws.systemPrompt.contains("香菜"), "相关记忆必须进 prompt")
    }

    func testSummarizedHistoryIsNotDuplicated() async {
        let persona = makePersona()
        var conversation = Conversation.direct(with: persona.id, title: "青")
        var history: [Message] = []
        for i in 0..<10 {
            history.append(Message(conversationID: conversation.id, authorID: nil, role: .user, text: "第\(i)句"))
        }
        let covered = history[4]
        conversation.digest = ConversationDigest(
            conversationID: conversation.id,
            summary: "你们聊过前五句。",
            coveredUpToMessageID: covered.id,
            openThreads: [],
            emotionalArc: "平稳"
        )

        let engine = ContextEngine(embedder: HashingEmbedder())
        let ws = await engine.workingSet(
            persona: persona, conversation: conversation, history: history,
            memories: [], canon: nil,
            edge: RelationshipEdge(fromID: persona.id, toID: nil),
            settings: .standard, userInput: "继续"
        )

        let joined = ws.messages.map { $0.content }.joined()
        XCTAssertTrue(joined.contains("你们聊过前五句"), "摘要必须进上下文")
        XCTAssertFalse(joined.contains("第0句"), "已被摘要覆盖的原文不应重复注入")
        XCTAssertTrue(joined.contains("第9句"), "最新原文必须保留")
    }

    func testTokenEstimatorHandlesCJK() {
        XCTAssertGreaterThan(TokenEstimator.estimate("你好世界"), 3)
        XCTAssertLessThan(TokenEstimator.estimate("hello world"), 6)
    }
}
