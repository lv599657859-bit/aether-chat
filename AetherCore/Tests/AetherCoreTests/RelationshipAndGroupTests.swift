import XCTest
@testable import AetherCore

/// 关系与群聊编排测试。
/// 「他们甚至会自己发展出关系」这句话，必须能在测试里被验证。
final class RelationshipAndGroupTests: XCTestCase {
    private let engine = RelationshipEngine()

    func testComplimentRaisesAffinity() {
        let base = RelationshipEdge(fromID: UUID(), toID: nil)
        let updated = engine.updateUserEdge(base, userText: "你今天真好，谢谢你", personaReplied: true)
        XCTAssertGreaterThan(updated.affinity, base.affinity)
        XCTAssertGreaterThan(updated.familiarity, base.familiarity)
    }

    func testInsultRaisesTension() {
        let base = RelationshipEdge(fromID: UUID(), toID: nil)
        let updated = engine.updateUserEdge(base, userText: "你真笨，闭嘴", personaReplied: true)
        XCTAssertGreaterThan(updated.tension, base.tension)
        XCTAssertLessThan(updated.affinity, base.affinity)
    }

    func testSharingSecretRaisesTrustAndLogsMilestone() {
        let base = RelationshipEdge(fromID: UUID(), toID: nil, affinity: 0.6)
        let updated = engine.updateUserEdge(base, userText: "我告诉你一个秘密，别告诉别人", personaReplied: true)
        XCTAssertGreaterThan(updated.trust, base.trust)
        XCTAssertTrue(updated.milestones.contains { $0.label == "交心" })
    }

    func testDecayPullsRelationshipBackToBaseline() {
        var edge = RelationshipEdge(fromID: UUID(), toID: nil, affinity: 0.9)
        edge.lastInteractionAt = Date().addingTimeInterval(-30 * 86_400)
        var decayed = edge
        decayed.decay()
        XCTAssertLessThan(decayed.affinity, edge.affinity, "长期不联系，关系必须变淡")
    }

    func testKindIsDerivedFromNumbers() {
        var edge = RelationshipEdge(fromID: UUID(), toID: nil, affinity: 0.9, trust: 0.9)
        edge.reevaluateKind()
        XCTAssertEqual(edge.kind, .closeFriend)

        var hostile = RelationshipEdge(fromID: UUID(), toID: nil, affinity: -0.7, tension: 0.9)
        hostile.reevaluateKind()
        XCTAssertEqual(hostile.kind, .nemesis)
    }

    func testInterCharacterAdvanceCanProduceMilestone() {
        let edge = RelationshipEdge(fromID: UUID(), toID: UUID(), affinity: 0.55, trust: 0.55)
        let result = engine.advanceInterCharacter(edge, chemistry: 0.9, friction: 0, note: "他们聊得不错")
        XCTAssertGreaterThan(result.edge.affinity, edge.affinity)
        XCTAssertNotNil(result.milestone, "关系升级必须留下里程碑")
    }

    @MainActor
    func testAddressedPersonaSpeaksFirst() {
        let a = PersonaFactory.forgeOriginal(name: "青", seed: .empty)
        let b = PersonaFactory.forgeOriginal(name: "白", seed: .empty)
        let conversation = Conversation.group(title: "测试群", members: [
            Participant(personaID: a.id, chattiness: 0.1),
            Participant(personaID: b.id, chattiness: 0.9),
        ])
        let director = GroupDirector()
        let turns = director.planTurns(
            conversation: conversation,
            personas: [a, b],
            edges: [],
            lastUserText: "青，你怎么看",
            recentSpeakerIDs: [],
            maxTurns: 1
        )
        XCTAssertEqual(turns.first?.personaID, a.id, "被点名的人必须优先接话")
    }

    @MainActor
    func testRecentSpeakerYields() {
        let a = PersonaFactory.forgeOriginal(name: "青", seed: .empty)
        let b = PersonaFactory.forgeOriginal(name: "白", seed: .empty)
        let conversation = Conversation.group(title: "测试群", members: [
            Participant(personaID: a.id, chattiness: 0.8),
            Participant(personaID: b.id, chattiness: 0.8),
        ])
        let director = GroupDirector()
        let turns = director.planTurns(
            conversation: conversation,
            personas: [a, b],
            edges: [],
            lastUserText: "随便说点什么",
            recentSpeakerIDs: [a.id, a.id, a.id],
            maxTurns: 1
        )
        XCTAssertNotEqual(turns.first?.personaID, a.id, "刚说完的人要让一让")
    }
}
