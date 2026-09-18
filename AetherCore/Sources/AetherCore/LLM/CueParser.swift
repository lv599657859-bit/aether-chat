import Foundation

/// 流式演出指令解析器 —— 整个演出系统的入口。
///
/// 模型吐出的是带舞台指示的文本：
///   今天…⟦c:avatar.blush:0.7⟧那个…⟦c:pacing.split⟧其实我等你很久了。
/// 解析器负责：
///   1. 把 ⟦c:...⟧ 抠出来变成 PerformanceCue（并记录字符偏移）
///   2. 把 ⟦e:...⟧ 变成情绪向量
///   3. 把 ⟦m:...⟧ 变成内心独白（**永不显示**，只进隐藏层）
///   4. 返回干净的显示文本
///
/// 关键约束：增量流式。半个标记跨 chunk 到达时必须憋住，不能把 「⟦c:ava」
/// 当正文吐到屏幕上 —— 那会瞬间破坏沉浸感。
struct CueStreamParser {
    struct Output {
        var display: String = ""
        var cues: [PerformanceCue] = []
        var emotion: EmotionState?
        var monologue: String?
        var emittedChars: Int = 0
    }

    private let open: Character = "⟦"
    private let close: Character = "⟧"
    private var buffer = ""            // 尚未闭合的标记
    private var inside = false
    private var displayLength = 0

    /// 喂入一个流式分片，返回这一片里「可以安全落屏」的文本与解析出的指令。
    mutating func feed(_ chunk: String) -> Output {
        var out = Output()
        for ch in chunk {
            if inside {
                if ch == close {
                    inside = false
                    consume(marker: buffer, into: &out)
                    buffer = ""
                } else {
                    buffer.append(ch)
                }
                continue
            }
            if ch == open {
                inside = true
                continue
            }
            out.display.append(ch)
            displayLength += 1
        }
        out.emittedChars = displayLength
        return out
    }

    /// 流结束时调用。若还有没闭合的标记，按普通文本吐出来，绝不吞字。
    mutating func finish() -> Output {
        var out = Output()
        if !buffer.isEmpty || inside {
            out.display = String(open) + buffer
            buffer = ""
            inside = false
            displayLength += out.display.count
        }
        out.emittedChars = displayLength
        return out
    }

    private mutating func consume(marker raw: String, into out: inout Output) {
        let marker = raw.trimmed
        guard !marker.isEmpty else { return }

        // ⟦e:v=0.6,a=0.8,d=0.4,label=羞恼/心跳⟧
        if marker.hasPrefix("e:") {
            let body = String(marker.dropFirst(2))
            if let emo = EmotionState.parse(body) { out.emotion = emo }
            return
        }

        // ⟦m:他好像不太高兴…⟧ 内心独白
        if marker.hasPrefix("m:") {
            out.monologue = String(marker.dropFirst(2)).trimmed
            return
        }

        // ⟦c:channel.name:intensity⟧
        guard marker.hasPrefix("c:") else { return }
        let body = String(marker.dropFirst(2))
        let parts = body.split(separator: ":", maxSplits: 2).map { String($0).trimmed }
        guard let path = parts.first else { return }
        let pair = path.split(separator: ".", maxSplits: 1).map { String($0).trimmed }
        guard pair.count == 2,
              let channel = PerformanceCue.Channel(rawValue: pair[0]) else { return }

        let intensity = parts.count > 1 ? (Double(parts[1]) ?? 0.6) : 0.6
        let delay = parts.count > 2 ? (Double(parts[2]) ?? 0) : defaultDelay(for: pair[1])
        let cue = PerformanceCue(
            at: displayLength,
            channel: channel,
            name: pair[1],
            intensity: intensity,
            delay: delay
        )
        guard CueVocabulary.isAllowed(cue) else {
            Log.stage.debug("dropped unknown cue: \(path)")
            return
        }
        out.cues.append(cue)
    }

    /// 打字机、停顿这类指令自带节拍。
    private func defaultDelay(for name: String) -> Double {
        switch name {
        case "typewriter": return 0.3
        case "split": return 0.9
        case "blush", "lookaway", "freeze": return 0.2
        default: return 0
        }
    }
}

/// 一次性解析（非流式场景，例如历史消息回放、单元测试）。
enum CueParser {
    static func parse(_ text: String) -> CueStreamParser.Output {
        var parser = CueStreamParser()
        var out = parser.feed(text)
        let tail = parser.finish()
        out.display += tail.display
        return out
    }
}
