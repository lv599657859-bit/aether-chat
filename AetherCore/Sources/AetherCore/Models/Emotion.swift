import Foundation

/// 三维情绪向量。所有演出（表情 / 动作 / 气泡 / 屏幕特效 / 震动）都由它驱动，
/// 而不是让模型直接输出动画名 —— 模型只表达「感觉」，引擎决定「怎么演」。
struct EmotionState: Codable, Hashable, Sendable {
    /// -1 极度排斥 … +1 极度愉悦
    var valence: Double
    /// 0 静如止水 … 1 心潮翻涌
    var arousal: Double
    /// 0 顺从退让 … 1 主导压迫
    var dominance: Double
    /// 人话标签，用于 UI 与调参，如 ["羞恼", "故作镇定"]
    var labels: [String]

    static let neutral = EmotionState(valence: 0, arousal: 0.2, dominance: 0.5, labels: ["平静"])

    var dominantLabel: String { labels.first ?? "平静" }

    /// 情绪平滑：演出不瞬变，永远插值过渡。
    func blended(with other: EmotionState, t: Double) -> EmotionState {
        let k = t.clamped(0, 1)
        return EmotionState(
            valence: valence.lerp(to: other.valence, k),
            arousal: arousal.lerp(to: other.arousal, k),
            dominance: dominance.lerp(to: other.dominance, k),
            labels: k > 0.5 ? other.labels : labels
        )
    }

    /// 从模型输出的一行解析，容错：缺字段不炸。
    static func parse(_ raw: String) -> EmotionState? {
        let parts = raw.split(separator: ",").map { String($0).trimmed }
        guard !parts.isEmpty else { return nil }
        var v = 0.0, a = 0.2, d = 0.5
        var labels: [String] = []
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "v", "valence": v = Double(kv[1]) ?? v
            case "a", "arousal": a = Double(kv[1]) ?? a
            case "d", "dominance": d = Double(kv[1]) ?? d
            case "label", "labels": labels = kv[1].split(separator: "/").map { String($0).trimmed }
            default: break
            }
        }
        return EmotionState(valence: v.clamped(-1, 1), arousal: a.clamped(0, 1), dominance: d.clamped(0, 1), labels: labels)
    }
}
