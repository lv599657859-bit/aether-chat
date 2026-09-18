import Foundation
import AVFoundation

/// 系统音色清单。
///
/// iOS 自带几十个中英文音色，质量差异很大（有的还是「紧凑」版的合成音）。
/// 这一层负责把它们整理成可挑选的列表，并按角色特征推荐一个。
enum VoiceCatalog {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var language: String
        var gender: String
        var quality: String

        var displayName: String { "\(name) · \(language) · \(gender)" }
        var isPremium: Bool { quality != "默认" }
    }

    /// 全部可用音色。
    static func all() -> [Entry] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            Entry(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                gender: genderName(voice.gender),
                quality: qualityName(voice.quality)
            )
        }
        .sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l != r { return l < r }
            return lhs.name < rhs.name
        }
    }

    /// 中文音色优先。
    static func chinese() -> [Entry] {
        all().filter { $0.language.hasPrefix("zh") }
    }

    static func entry(for identifier: String?) -> Entry? {
        guard let identifier else { return nil }
        return all().first { $0.id == identifier }
    }

    /// 按性别与语言挑一个质量最好的。
    static func best(gender: String, languagePrefix: String = "zh") -> Entry? {
        let pool = all().filter { $0.language.hasPrefix(languagePrefix) }
        let gendered = pool.filter { $0.gender == gender }
        return (gendered.isEmpty ? pool : gendered).min { rank($0) < rank($1) }
    }

    /// 排序权重：中文 > 英文 > 其他；高质量 > 默认。
    private static func rank(_ entry: Entry) -> Int {
        var score = 0
        if entry.language.hasPrefix("zh") { score += 0 }
        else if entry.language.hasPrefix("en") { score += 100 }
        else { score += 200 }
        if entry.name.contains("Siri") { score += 40 }      // Siri 音色可用但风格强，排后一点
        if !entry.isPremium { score += 10 }
        return score
    }

    private static func genderName(_ gender: AVSpeechSynthesisVoiceGender) -> String {
        switch gender {
        case .male: return "男声"
        case .female: return "女声"
        default: return "中性"
        }
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: return "增强"
        case .premium: return "高级"
        default: return "默认"
        }
    }
}
