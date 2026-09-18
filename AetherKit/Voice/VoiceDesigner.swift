import Foundation
import AVFoundation

/// 声音设计师 —— 给一个角色自动配一副嗓子。
///
/// 这是「自动生成角色语音」的起点：不是随便挑一个系统音，而是
/// 从她的性格、说话方式、外貌设定里推出音色的四个参数
/// （音高 / 语速 / 性别倾向 / 音色描述），再落到一个具体音色上。
///
/// 分两条路：
///   - 有模型：让模型读她的人格，输出音色描述
///   - 没模型：从关键词做启发式推断 —— 保证离线也可用
final class VoiceDesigner: @unchecked Sendable {
    struct Design: Sendable {
        var timbrePrompt: String
        var rate: Float
        var pitch: Float
        var gender: String        // 男声 / 女声 / 中性
        var voiceID: String?
        var note: String          // 给人看的一句说明

        var profile: VoiceProfile {
            var p = VoiceProfile()
            p.systemVoiceID = voiceID
            p.rate = rate
            p.pitch = pitch
            p.timbrePrompt = timbrePrompt
            return p
        }
    }

    private let provider: LLMProvider?

    init(provider: LLMProvider? = ProviderHub.shared.llm) {
        self.provider = provider
    }

    func design(for persona: Persona) async -> Design {
        let offline = deriveOffline(from: persona)
        guard let provider, provider.id != "mock" else { return offline }

        let prompt = """
        给下面这个角色设计配音音色。

        名字：\(persona.core.name)
        一句话：\(persona.core.seed.oneLine)
        来历：\(persona.core.seed.background)
        说话方式：\(persona.core.seed.speechStyle)
        口癖：\(persona.core.speechQuirks.joined(separator: "、"))
        性格内核：\(persona.core.soul.prefix(300))

        只输出 JSON，不要解释：
        {
          "gender": "男声" 或 "女声" 或 "中性",
          "timbre": "音色描述，一句话。要具体到质感、年龄感、气声多少、尾音习惯。例如：偏低的女声，气声多，语速慢，尾音习惯往上挑一点",
          "rate": 0.0 到 1.0 之间的数，语速。偏低沉慢一点给 0.35，活泼快一点给 0.65,
          "pitch": 0.6 到 1.5 之间的数，音高。低沉给 0.85，清亮给 1.15
        }
        """

        do {
            var output = ""
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .system, content: "你是配音导演。只输出 JSON。"),
                    LLMMessage(role: .user, content: prompt),
                ],
                temperature: 0.6,
                maxTokens: 300,
                model: ""
            )
            for try await delta in provider.stream(request) { output += delta }

            guard let start = output.firstIndex(of: "{"),
                  let end = output.lastIndex(of: "}"),
                  start < end,
                  let data = String(output[start...end]).data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return offline }

            let gender = (dict["gender"] as? String) ?? offline.gender
            let timbre = (dict["timbre"] as? String)?.trimmed ?? offline.timbrePrompt
            let rate = Float((dict["rate"] as? Double) ?? Double(offline.rate))
            let pitch = Float((dict["pitch"] as? Double) ?? Double(offline.pitch))

            var design = Design(
                timbrePrompt: timbre,
                rate: rate.clamped(0.2, 0.8),
                pitch: pitch.clamped(0.6, 1.5),
                gender: gender,
                voiceID: nil,
                note: "由模型从人格推导"
            )
            design.voiceID = await VoiceCatalog.best(gender: gender)?.id
            return design
        } catch {
            Log.voice.error("voice design failed: \(error.localizedDescription)")
            return offline
        }
    }

    /// 离线推断：从说话方式和性格内核里捞关键词。
    /// 粗糙，但方向基本对 —— 一个说话很慢的人不该配一副机关枪嗓子。
    func deriveOffline(from persona: Persona) -> Design {
        let text = [
            persona.core.seed.speechStyle,
            persona.core.seed.oneLine,
            persona.core.seed.background,
            persona.core.soul,
            persona.core.speechQuirks.joined(separator: " "),
        ].joined(separator: " ")

        var rate: Float = 0.48
        var pitch: Float = 1.0
        var traits: [String] = []

        let slowWords = ["慢", "缓", "温吞", "沉", "低", "懒", "悠", "不紧不慢", "一字一句"]
        let fastWords = ["快", "利落", "机关枪", "急促", "活泼", "跳", "连珠"]
        let lowWords = ["低", "沙", "哑", "冷", "沉", "慵懒", "磁性"]
        let highWords = ["清亮", "高", "脆", "甜", "少女", "尖", "亮"]

        if slowWords.contains(where: { text.contains($0) }) { rate = 0.38; traits.append("语速偏慢") }
        if fastWords.contains(where: { text.contains($0) }) { rate = 0.62; traits.append("语速偏快") }
        if lowWords.contains(where: { text.contains($0) }) { pitch = 0.86; traits.append("音色偏低沉") }
        if highWords.contains(where: { text.contains($0) }) { pitch = 1.16; traits.append("音色偏清亮") }

        // 性别倾向：先看设定里的自称，再看代词出现次数
        let female = text.components(separatedBy: "她").count - 1
        let male = text.components(separatedBy: "他").count - 1
        let gender: String
        if female > male + 1 { gender = "女声" }
        else if male > female + 1 { gender = "男声" }
        else { gender = "中性" }

        let timbre = traits.isEmpty
            ? "自然的中性音色，语速适中，不要播音腔"
            : traits.joined(separator: "，") + "，不要播音腔"

        return Design(
            timbrePrompt: timbre,
            rate: rate,
            pitch: pitch,
            gender: gender,
            voiceID: nil,
            note: traits.isEmpty ? "按默认配置（设定里没有明显的语音线索）" : "从说话方式推断"
        )
    }

    /// 落地：把设计结果解析成具体的系统音色 id。
    func resolve(_ design: Design) -> VoiceProfile {
        var profile = design.profile
        if profile.systemVoiceID == nil {
            profile.systemVoiceID = VoiceCatalog.best(gender: design.gender)?.id
        }
        return profile
    }

    /// 试听用的样例台词。
    static func sampleLine(for persona: Persona) -> String {
        let quirk = persona.core.speechQuirks.first.map { "……\($0)。" } ?? ""
        let line = persona.core.seed.oneLine.trimmed
        if line.isEmpty {
            return "嗯……你来了。\(quirk)"
        }
        return "\(line)。\(quirk)"
    }
}
