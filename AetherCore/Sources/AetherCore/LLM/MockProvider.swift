import Foundation

/// 离线演示引擎。
///
/// 存在的意义：**没有 API Key 也能完整体验整个 app** ——
/// 演出系统、上下文引擎、关系演化、群聊编排全都能跑通。
/// 它不聪明，但它会让每一层管线都被真正执行到，而不是被 mock 掉。
final class MockProvider: LLMProvider, @unchecked Sendable {
    let id = "mock"
    let displayName = "离线演示引擎"

    private let latency: UInt64

    init(latencyMilliseconds: UInt64 = 38) {
        self.latency = latencyMilliseconds
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let system = request.messages.first(where: { $0.role == .system })?.content ?? ""
                let name = Self.extractName(from: system)
                let lastUser = request.messages.last(where: { $0.role == .user })?.content ?? ""
                let tension = Self.extractNumber(system, label: "张力") ?? 0
                let affinity = Self.extractNumber(system, label: "好感") ?? 0
                let isGroup = system.contains("这是群聊")

                let reply = Self.compose(
                    name: name,
                    userText: lastUser,
                    affinity: affinity,
                    tension: tension,
                    isGroup: isGroup,
                    request: request
                )

                var buffer = ""
                for character in reply {
                    buffer.append(character)
                    // 按「块」吐字，比逐字更接近真实网络流
                    if buffer.count >= 3 {
                        continuation.yield(buffer)
                        buffer = ""
                        try? await Task.sleep(nanoseconds: latency * 1_000_000)
                    }
                    if Task.isCancelled { continuation.finish(); return }
                }
                if !buffer.isEmpty { continuation.yield(buffer) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 组装回复

    private static func compose(
        name: String,
        userText: String,
        affinity: Double,
        tension: Double,
        isGroup: Bool,
        request: LLMRequest
    ) -> String {
        var pieces: [String] = []

        if isGroup {
            pieces.append("⟦c:avatar.tilt:0.4⟧")
        }

        if tension > 0.55 {
            pieces.append("⟦c:avatar.lookaway:0.6⟧⟦c:bubble.typewriter⟧")
            pieces.append("……")
            pieces.append("⟦c:pacing.split:0.9⟧")
            pieces.append("嗯。")
            pieces.append("⟦c:avatar.sigh:0.4⟧")
        } else if affinity > 0.7 {
            pieces.append("⟦c:avatar.smile:0.8⟧⟦c:stage.sparkle:0.3⟧")
            pieces.append("你来啦。")
            pieces.append("⟦c:pacing.split:0.7⟧")
            pieces.append("我刚还在想，你今天怎么这么安静。")
            pieces.append("⟦c:avatar.leanin:0.5⟧")
        } else if userText.contains("?") || userText.contains("？") || userText.contains("吗") {
            pieces.append("⟦c:avatar.thinking:0.5⟧")
            pieces.append("嗯……让我想想。")
            pieces.append("⟦c:pacing.split:0.8⟧")
            pieces.append("这种事情，说得太满反而没意思。")
        } else if userText.isEmpty {
            pieces.append("⟦c:avatar.stretch:0.4⟧")
            pieces.append("嗯？")
        } else {
            let echo = userText.count > 18 ? String(userText.prefix(12)) + "…" : userText
            pieces.append("⟦c:bubble.typewriter⟧")
            pieces.append("「\(echo)」")
            pieces.append("⟦c:pacing.split:0.6⟧")
            pieces.append("你说这话的时候，我大概能猜到你的表情。")
            pieces.append("⟦c:avatar.smile:0.5⟧")
        }

        // 情绪行 —— 与上面选的语气一致
        let emotion: String
        if tension > 0.55 {
            emotion = "⟦e:v=-0.45,a=0.55,d=0.4,label=别扭/隐忍⟧"
        } else if affinity > 0.7 {
            emotion = "⟦e:v=0.72,a=0.5,d=0.5,label=高兴/柔软⟧"
        } else {
            emotion = "⟦e:v=0.2,a=0.35,d=0.5,label=平静/留神⟧"
        }
        pieces.append(emotion)
        pieces.append("⟦m:（离线演示引擎在替她说话。接上真实模型后，这里会是她自己想的。）⟧")

        return pieces.joined()
    }

    private static func extractName(from system: String) -> String {
        guard let range = system.range(of: "你叫 ") else { return "她" }
        let rest = system[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == "。" || $0 == "，" || $0 == "\n" }) ?? rest.endIndex
        let name = String(rest[..<end]).trimmed
        return name.isEmpty ? "她" : name
    }

    private static func extractNumber(_ system: String, label: String) -> Double? {
        guard let range = system.range(of: label) else { return nil }
        let tail = system[range.upperBound...].prefix(12)
        let digits = tail.compactMap { $0.isNumber || $0 == "." || $0 == "-" ? $0 : nil }
        return Double(String(digits))
    }
}
