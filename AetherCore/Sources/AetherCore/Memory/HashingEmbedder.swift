import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// 零依赖本地向量化。
///
/// 为什么需要它：长期记忆检索不能因为「用户还没填 API Key」就整个瘫痪。
/// 这个实现用字符 n-gram 哈希投影到固定维度，检索质量不如真 embedding，
/// 但**离线可用、确定性、中文友好**，足够让整套上下文引擎跑通并可测。
/// 配好 Key 之后自动切到 OpenAIEmbeddingProvider，上层无感。
final class HashingEmbedder: EmbeddingProvider, @unchecked Sendable {
    private let dimensions: Int

    init(dimensions: Int = 256) {
        self.dimensions = dimensions
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vector(for: $0) }
    }

    func vector(for text: String) -> [Float] {
        var buckets = [Float](repeating: 0, count: dimensions)
        let chars = Array(text.lowercased())

        // 中文按字 n-gram，英文按字符 n-gram —— 中文没有空格，按词切会全废。
        for n in 1...3 {
            guard chars.count >= n else { continue }
            for i in 0...(chars.count - n) {
                let gram = String(chars[i..<(i + n)])
                if gram.isBlank { continue }

                // 关键：桶位与符号都从 SHA-256 摘要里取，不用 String.hashValue。
                // Swift 的 hashValue 每个进程随机播种，用它会让同一段文字在
                // 两次启动之间落到不同维度上 —— 持久化的记忆向量会静默失效。
                let digest = gram.sha256Bytes
                let index = Int(((UInt32(digest[0]) << 8) | UInt32(digest[1])) % UInt32(dimensions))
                let sign: Float = (digest[2] & 1 == 0) ? 1 : -1
                buckets[index] += sign * weight(for: n)
            }
        }
        return VectorMath.normalize(buckets)
    }

    private func weight(for n: Int) -> Float {
        switch n {
        case 1: return 0.5
        case 2: return 1.0
        default: return 0.7
        }
    }
}

enum VectorMath {
    static func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-6 else { return v }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot          // 两边都已归一化
    }
}
