import Foundation

enum PersonaOrigin: String, Codable, Sendable, CaseIterable {
    case original       // 自己捏的
    case adapted        // 从作品复刻
}

/// 复刻精度：决定 canon 对模型的约束力有多硬。
enum CanonFidelity: String, Codable, Sendable, CaseIterable {
    case strict     // 精确复刻
    case faithful   // 忠于原作
    case inspired   // 灵感演绎
    case original   // 原创

    var displayName: String {
        switch self {
        case .strict: return "精确复刻"
        case .faithful: return "忠于原作"
        case .inspired: return "灵感演绎"
        case .original: return "原创角色"
        }
    }

    var enforcementLine: String {
        switch self {
        case .strict:
            return "你被要求严格复刻原作。任何与原作设定冲突的表述都不得出现；遇到作品未涉及的领域，宁可回避，或以角色的方式承认不清楚，绝不编造。"
        case .faithful:
            return "你以原作设定为不可动摇的骨架，只在原作未覆盖的日常细节上做符合性格的延展。"
        case .inspired:
            return "你借用原作的设定与气质，但不被其剧情束缚，可以自由演绎。"
        case .original:
            return ""
        }
    }
}

/// 人格种子：创建时定下的骨架。冻结后不可改。
struct PersonaSeed: Codable, Hashable, Sendable {
    var oneLine: String             // 一句话是谁
    var background: String          // 来历
    var coreDesire: String          // 最想要什么
    var wound: String               // 最怕什么 / 伤在哪
    var speechStyle: String         // 怎么说话
    var relationshipStance: String  // 默认怎么看待用户
    var interests: [String]
    var taboos: [String]

    static let empty = PersonaSeed(
        oneLine: "", background: "", coreDesire: "", wound: "",
        speechStyle: "", relationshipStance: "", interests: [], taboos: []
    )
}

/// 人格内核 —— 冻结后只读。这就是「一代设计，之后不再更改」。
struct PersonaCore: Codable, Hashable, Sendable {
    var name: String
    var handle: String
    var origin: PersonaOrigin
    var sourceWork: String?
    var fidelity: CanonFidelity
    var seed: PersonaSeed
    /// 写进 system prompt 的人格正文（第二人称）
    var soul: String
    var speechQuirks: [String]
    var taboos: [String]
    var canonBundleID: UUID?
    var createdAt: Date
    var frozenAt: Date?
    var version: Int
    /// 冻结时算出的指纹。UI 用它显示「未被改动」。
    var fingerprint: String

    /// 指纹只覆盖身份字段，presentation 不参与。
    func computeFingerprint() -> String {
        let payload = [
            name, handle, origin.rawValue, sourceWork ?? "", fidelity.rawValue,
            seed.oneLine, seed.background, seed.coreDesire, seed.wound,
            seed.speechStyle, seed.relationshipStance,
            seed.interests.joined(separator: "|"), seed.taboos.joined(separator: "|"),
            soul, speechQuirks.joined(separator: "|"), taboos.joined(separator: "|"),
            canonBundleID?.uuidString ?? "",
        ].joined(separator: "\u{1F}")
        return payload.sha256Hex
    }

    var isIntact: Bool { fingerprint == computeFingerprint() }

    static func blank(name: String) -> PersonaCore {
        PersonaCore(
            name: name,
            handle: "@" + name.lowercased().replacingOccurrences(of: " ", with: "_"),
            origin: .original,
            sourceWork: nil,
            fidelity: .original,
            seed: .empty,
            soul: "",
            speechQuirks: [],
            taboos: [],
            canonBundleID: nil,
            createdAt: Date(),
            frozenAt: nil,
            version: 0,
            fingerprint: ""
        )
    }
}

/// 表现层 —— 随便改，不影响人格。换皮不换人。
struct PersonaPresentation: Codable, Hashable, Sendable {
    var avatarKind: AvatarKind = .orb
    var avatarAssetName: String?
    /// 锁脸锚点：生成任何图片都必须带上它，保证是同一个人。
    var appearanceAnchor: String = ""
    var palette: [String] = ["#8A7BFF", "#FFB4C8"]
    var voice: VoiceProfile = VoiceProfile.standard
    /// 打字节奏：0 秒回 … 1 慢吞吞
    var typingTempo: Double = 0.5
    /// 主动程度：会不会主动找你
    var proactiveLevel: Double = 0.4
    /// 睡觉时段 [start, end)，这期间不主动打扰
    var sleepWindow: [Int] = [1, 6]
    var isMuted: Bool = false
    var isPinned: Bool = false
}

enum AvatarKind: String, Codable, Sendable, CaseIterable {
    case live2D     // 2D 立绘（Cubism）
    case threeD     // 3D 形象（VRM / USDZ）
    case sprite     // 静态分层立绘 + 程序化呼吸
    case orb        // 无素材时的占位光核

    var displayName: String {
        switch self {
        case .live2D: return "2D 立绘"
        case .threeD: return "3D 形象"
        case .sprite: return "立绘卡"
        case .orb:    return "光核"
        }
    }
}

struct VoiceProfile: Codable, Hashable, Sendable {
    var systemVoiceID: String?
    var rate: Float = 0.5
    var pitch: Float = 1.0
    var volume: Float = 1.0
    /// 云端 TTS 的音色描述（用于复刻角色声线）
    var timbrePrompt: String = ""
    static let standard = VoiceProfile()
}

struct SealRecord: Codable, Hashable, Sendable {
    var version: Int
    var fingerprint: String
    var sealedAt: Date
    var reason: String
}

/// 一个 AI 联系人。
struct Persona: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var core: PersonaCore
    var presentation = PersonaPresentation()
    var seals: [SealRecord] = []
    var isFrozen: Bool = false
    /// 该角色的长期记忆流
    var memoryStreamID: UUID = UUID()

    var name: String { core.name }
    var fidelity: CanonFidelity { core.fidelity }
    var hasCanon: Bool { core.canonBundleID != nil }
    var avatarKind: AvatarKind { presentation.avatarKind }

    /// 冻结：把当前 core 钉死，留下一枚印章。
    mutating func freeze(reason: String) {
        let fp = core.computeFingerprint()
        core.fingerprint = fp
        core.frozenAt = Date()
        core.version += 1
        isFrozen = true
        seals.append(SealRecord(version: core.version, fingerprint: fp, sealedAt: Date(), reason: reason))
    }

    /// 重铸：只有用户明确要求「重塑人格」时才会走到这里，且必然留痕。
    mutating func reforge(reason: String, mutate: (inout PersonaCore) -> Void) {
        mutate(&core)
        freeze(reason: reason)
    }
}
