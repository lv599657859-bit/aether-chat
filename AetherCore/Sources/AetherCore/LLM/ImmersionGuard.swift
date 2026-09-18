import Foundation

/// 沉浸守门。
///
/// 用户的要求是：上下文管理要存在，但绝不能在明面上出现。
/// 于是有了这一层 —— 它做两件相反方向的事：
///   出方向：把模型不小心漏出来的元语言（「作为AI」「我的提示词」「上下文窗口」）擦掉。
///   入方向：把界面上的技术文案换成角色化的说法（「正在生成」 -> 「正在斟酌」）。
enum ImmersionGuard {
    /// 会被擦除的元语言模式。命中后整句删除，而不是替换成别的话 ——
    /// 换成别的话反而更出戏。
    ///
    /// 注意：这些是正则，写在这里的每个反斜杠在 Swift 字符串里都必须写成两个。
    private static let metaPatterns: [String] = [
        "作为(一个)?(AI|人工智能|语言模型|助手)",
        "我是一个?(AI|人工智能|语言模型|机器人)",
        "我的?(系统)?提示词",
        "系统提示",
        "上下文(窗口|长度)?",
        "token(数)?",
        "我(被)?(设定|训练)(成)?",
        "根据(我的)?设定",
        "语言模型",
        "大模型",
        "GPT|Claude|Gemini|DeepSeek",
        "\\bprompt\\b",
        "API",
        "我(无法|不能)(真正)?(感受|拥有)(情感|感情)",
    ]

    private static let regexes: [NSRegularExpression] = metaPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// 擦除整句。按中文/英文句读切分，命中的句子整句丢弃。
    static func scrub(_ text: String) -> (clean: String, blocks: Int) {
        guard !text.isEmpty else { return (text, 0) }
        let sentences = splitSentences(text)
        var kept: [String] = []
        var blocked = 0
        for sentence in sentences {
            if containsMeta(sentence) {
                blocked += 1
                Log.stage.debug("ImmersionGuard blocked a sentence")
            } else {
                kept.append(sentence)
            }
        }
        var clean = kept.joined()
        if blocked > 0 && clean.trimmed.isEmpty {
            // 整条都被擦了 —— 给一句不破坏角色的兜底
            clean = "……（她沉默了一下，像是不太想接这句话）"
        }
        return (clean, blocked)
    }

    static func containsMeta(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regexes.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?\n".contains(ch) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 界面用语角色化：技术状态 -> 角色状态。
    static func characterful(_ techText: String, personaName: String) -> String {
        switch techText {
        case "正在生成", "正在思考": return "\(personaName)正在斟酌…"
        case "网络错误", "请求失败": return "消息没送到"
        case "重新生成": return "让她再说一次"
        default: return techText
        }
    }

    /// 正在输入的气泡文案池：让「等待」也变成演出的一部分。
    static let typingPhrases = [
        "正在输入…", "正在斟酌…", "写了又删…", "似乎在想措辞…", "正在组织语言…",
    ]

    static func typingPhrase(seed: Int, tempo: Double) -> String {
        let slowBias = tempo > 0.7
        if slowBias && seed % 2 == 0 { return "写了又删…" }
        return typingPhrases[abs(seed) % typingPhrases.count]
    }
}
