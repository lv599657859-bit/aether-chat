import XCTest
@testable import AetherCore

/// 人格固化测试。
/// 用户的核心要求之一是「一代设计的人格，之后就不会更改」。
/// 这些用例就是那条承诺的技术兑现。
final class PersonaFidelityTests: XCTestCase {

    private func makeSeed() -> PersonaSeed {
        PersonaSeed(
            oneLine: "她是个总是说没事的人",
            background: "在海边长大",
            coreDesire: "被需要",
            wound: "被丢下",
            speechStyle: "句子很短，喜欢用句号",
            relationshipStance: "客气但疏离",
            interests: ["海", "旧唱片"],
            taboos: ["不会撒娇"]
        )
    }

    func testFreezeLocksFingerprint() {
        let persona = PersonaFactory.forgeOriginal(name: "青", seed: makeSeed())
        XCTAssertTrue(persona.isFrozen)
        XCTAssertTrue(persona.core.isIntact)
        XCTAssertFalse(persona.core.fingerprint.isEmpty)
        XCTAssertEqual(persona.seals.count, 1)
    }

    /// 改表现层不该影响人格指纹 —— 换皮不换人。
    func testPresentationChangesDoNotTouchIdentity() {
        var persona = PersonaFactory.forgeOriginal(name: "青", seed: makeSeed())
        let before = persona.core.fingerprint
        persona.presentation.avatarKind = .threeD
        persona.presentation.voice.pitch = 1.3
        persona.presentation.typingTempo = 0.9
        XCTAssertEqual(persona.core.fingerprint, before)
        XCTAssertTrue(persona.core.isIntact)
    }

    /// 偷改内核必须被指纹抓出来。
    func testTamperingWithCoreBreaksIntegrity() {
        var persona = PersonaFactory.forgeOriginal(name: "青", seed: makeSeed())
        XCTAssertTrue(persona.core.isIntact)
        persona.core.seed.coreDesire = "想毁掉一切"
        XCTAssertFalse(persona.core.isIntact, "改内核必须导致指纹失配")
    }

    /// 重铸是允许的，但必须留痕、必须换指纹、必须升版本。
    func testReforgeLeavesSealAndNewFingerprint() {
        var persona = PersonaFactory.forgeOriginal(name: "青", seed: makeSeed())
        let original = persona.core.fingerprint
        persona.reforge(reason: "用户要求重塑") { core in
            core.seed.wound = "被背叛"
        }
        XCTAssertNotEqual(persona.core.fingerprint, original)
        XCTAssertTrue(persona.core.isIntact)
        XCTAssertEqual(persona.seals.count, 2)
        XCTAssertEqual(persona.core.version, 2)
        XCTAssertEqual(persona.seals.last?.reason, "用户要求重塑")
    }

    func testFidelityEnforcementTextExists() {
        for level in CanonFidelity.allCases where level != .original {
            XCTAssertFalse(level.enforcementLine.isEmpty, "\(level) 必须有约束文本")
        }
        XCTAssertTrue(CanonFidelity.original.enforcementLine.isEmpty)
    }
}
