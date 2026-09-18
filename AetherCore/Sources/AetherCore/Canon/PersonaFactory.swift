import Foundation

/// 人格铸造厂。
///
/// 这是整个 app 里唯一能「创造一个人」的地方，也是唯一一次允许改动人格内核。
/// 铸成之后立刻冻结 —— 用户的要求是「一代设计的人格，之后就不会更改」。
/// 从此以后，能改的只有表现层（换立绘、调音色、改打字速度），改不了她是谁。
enum PersonaFactory {

    /// 从研究草稿铸造。
    static func forge(draft: PersonaDraft) -> Persona {
        var core = draft.core
        if core.soul.isBlank {
            core.soul = fallbackSoul(for: core)
        }
        if core.seed.oneLine.isBlank {
            core.seed.oneLine = "\(core.name)，一个还没被写清楚的人。"
        }
        var persona = Persona(core: core)
        persona.presentation.appearanceAnchor = appearanceAnchor(from: draft)
        persona.freeze(reason: "初次铸造")
        Log.canon.info("persona forged: \(persona.name) v\(persona.core.version) fp=\(persona.core.fingerprint.prefix(8))")
        return persona
    }

    /// 从零手搓一个原创角色。
    static func forgeOriginal(
        name: String,
        seed: PersonaSeed,
        soul: String = "",
        sourceWork: String? = nil,
        fidelity: CanonFidelity = .original,
        canonBundleID: UUID? = nil
    ) -> Persona {
        var core = PersonaCore.blank(name: name)
        core.origin = .original
        core.seed = seed
        core.soul = soul.isBlank ? fallbackSoul(for: core) : soul
        core.sourceWork = sourceWork
        core.fidelity = fidelity
        core.canonBundleID = canonBundleID
        var persona = Persona(core: core)
        persona.presentation.appearanceAnchor = appearanceAnchorFromSeed(seed, name: name)
        persona.freeze(reason: "初次铸造")
        return persona
    }

    /// 没有 soul 时的兜底：用 seed 拼一段第二人称正文。
    /// 不惊艳，但保证「人格内核」这个字段永不为空 —— 空内核的人格会立刻漂移。
    private static func fallbackSoul(for core: PersonaCore) -> String {
        let seed = core.seed
        return """
        你是 \(core.name)。\(seed.oneLine)

        \(seed.background)

        你一直想要的是：\(seed.coreDesire)。这件事你没有对谁完整说过。
        你不太愿意碰的是：\(seed.wound)。别人靠近这个话题时，你会换一种说法绕开。

        你说话的方式：\(seed.speechStyle)

        你不是一个随时待命的人。你有自己的节奏、自己的事、自己不想说话的时候。
        你不必对每一个问题都给出有用的回答 —— 真人不会那样。
        """
    }

    /// 锁脸锚点：之后所有为这个角色生成的图片都必须带上这句话。
    /// 这是「同一个人的照片看起来像同一个人」的唯一保证。
    private static func appearanceAnchor(from draft: PersonaDraft) -> String {
        guard let bundle = draft.bundle else { return appearanceAnchorFromSeed(draft.core.seed, name: draft.core.name) }
        let appearance = bundle.facts(in: .appearance).prefix(6).map { $0.body }.joined(separator: "；")
        let identity = bundle.facts(in: .identity).prefix(2).map { $0.body }.joined(separator: "；")
        var parts: [String] = ["角色：\(bundle.characterName)（出自《\(bundle.workTitle)》）"]
        if !identity.isBlank { parts.append(identity) }
        if !appearance.isBlank { parts.append(appearance) }
        parts.append("保持一致的五官、发型、配色；不要换人")
        return parts.joined(separator: "。")
    }

    private static func appearanceAnchorFromSeed(_ seed: PersonaSeed, name: String) -> String {
        "角色：\(name)。\(seed.oneLine)。\(seed.background.prefix(40))。保持同一张脸、同一发型、同一配色。"
    }
}
