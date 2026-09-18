import Foundation

/// 一条原作设定。角色复刻的知识库最小单元。
struct CanonFact: Identifiable, Codable, Hashable, Sendable {
    enum Category: String, Codable, Sendable, CaseIterable {
        case identity    // 身份 / 别名 / 阵营
        case appearance  // 外貌 / 服装 / 特征
        case personality // 性格
        case speech      // 语气 / 口癖 / 称呼
        case ability     // 能力 / 战斗 / 道具
        case relation    // 人际关系
        case timeline    // 经历 / 年表
        case world       // 世界观 / 设定名词
        case taboo       // 禁忌 / 不可违背
        case quote       // 原台词样本

        var displayName: String {
            switch self {
            case .identity: return "身份"
            case .appearance: return "外貌"
            case .personality: return "性格"
            case .speech: return "语气"
            case .ability: return "能力"
            case .relation: return "关系"
            case .timeline: return "经历"
            case .world: return "世界观"
            case .taboo: return "禁忌"
            case .quote: return "原台词"
            }
        }
    }

    var id: UUID = UUID()
    var category: Category
    var title: String
    var body: String
    /// 0...1：来源数量与权威度综合
    var confidence: Double
    var sources: [CanonSource]
    /// 「铁律」条目无条件注入 prompt
    var isHard: Bool = false
    var conflictNote: String?

    var citation: String { sources.first.map { "《\($0.title)》" } ?? "—" }
}

struct CanonSource: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case wiki, fandom, moegirl, official, wikiData, manual, video, other

        var displayName: String {
            switch self {
            case .wiki: return "维基百科"
            case .fandom: return "Fandom"
            case .moegirl: return "萌娘百科"
            case .official: return "官方"
            case .wikiData: return "Wikidata"
            case .manual: return "用户手填"
            case .video: return "影像"
            case .other: return "其他"
            }
        }
    }
    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var url: String
    var fetchedAt: Date = Date()
}

/// 复刻产物：一个作品的全部可检索知识。
struct CanonBundle: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var workTitle: String
    var characterName: String
    var aliases: [String]
    var fidelity: CanonFidelity
    var facts: [CanonFact]
    var relationMap: [String: [String]]
    var glossary: [String: String]
    /// 口癖与台词样本：让模型学会「怎么说话」，而不是「说什么」
    var speechCorpus: [String]
    var createdAt: Date = Date()
    var fingerprint: String = ""

    var hardFacts: [CanonFact] { facts.filter { $0.isHard } }

    func facts(in category: CanonFact.Category) -> [CanonFact] {
        facts.filter { $0.category == category }
    }
}

/// 研究阶段的中间产物：交给用户审核的草稿。
struct PersonaDraft: Identifiable, Sendable {
    var id: UUID = UUID()
    var core: PersonaCore
    var bundle: CanonBundle?
    var openQuestions: [String] = []
    var warnings: [String] = []
    var researchLog: [String] = []
}
