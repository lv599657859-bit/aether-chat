import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}

extension Date {
    var iso8601: String { ISO8601DateFormatter().string(from: self) }
}

extension Array where Element == Float {
    /// 归一化到 0...1，用于语音波形绘制。
    func normalizedPeaks() -> [Float] {
        guard let maxV = map({ abs($0) }).max(), maxV > 0 else { return self }
        return map { min(1, abs($0) / maxV) }
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
    func lerp(to other: Double, _ t: Double) -> Double { self + (other - self) * t }
}

/// 中文友好的 token 估算：CJK 约 1 字 = 1 token，英文约 4 字符 = 1 token。
///
/// 不需要精确 —— 它的用途是让上下文预算有个数量级正确的把握，
/// 精度差 20% 对「这一层放不放得下」的判断没有影响。
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return cjk + max(1, other / 4)
    }

    static func estimate(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1.content) + 4 }
    }
}
