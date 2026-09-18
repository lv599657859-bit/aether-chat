import Foundation
import UIKit

/// 影像工作室 —— 角色的「日常照片」和「自拍」从这里出来。
///
/// 最关键的一件事是**锁脸**：同一个角色的每一张照片都必须像同一个人。
/// 纯靠 prompt 是锁不住的，所以这里用的是三层锚定：
///   1. appearanceAnchor（从 canon 抽出的外貌事实，创建时固化，永不改）
///   2. 参考图（用户上传的角色立绘，作为图像参考传入）
///   3. 固定的构图模板（同样的机位、同样的光线习惯，视觉上形成"这是她拍的"）
final class ImageStudio: @unchecked Sendable {
    private let provider: ImageProvider?
    private let captioner: LLMProvider?

    init(provider: ImageProvider?, captioner: LLMProvider? = ProviderHub.shared.llm) {
        self.provider = provider
        self.captioner = captioner
    }

    enum Scene: String, CaseIterable, Sendable {
        case selfie       // 自拍
        case cafe         // 在咖啡馆
        case commute      // 通勤路上
        case night        // 深夜
        case food         // 在吃东西
        case desk         // 书桌前
        case window       // 窗边
        case street       // 街上

        var displayName: String {
            switch self {
            case .selfie: return "自拍"
            case .cafe: return "咖啡馆"
            case .commute: return "路上"
            case .night: return "深夜"
            case .food: return "吃饭"
            case .desk: return "桌前"
            case .window: return "窗边"
            case .street: return "街头"
            }
        }

        /// 固定的机位与光线习惯 —— 让照片有"同一个人拍的"的一致性
        var framing: String {
            switch self {
            case .selfie: return "手机前置自拍，手臂微微伸出，略微仰角，背景虚化"
            case .cafe: return "坐在桌边，半身，暖色顶光，桌上有杯子"
            case .commute: return "走动中抓拍，略微运动模糊，自然光"
            case .night: return "夜晚室内，单一暖色光源，暗部很沉"
            case .food: return "俯拍餐桌，手入画一角"
            case .desk: return "书桌前的侧后方视角，屏幕光打在脸上"
            case .window: return "逆光坐在窗边，轮廓光明显"
            case .street: return "街头随手一拍，行人与招牌虚化"
            }
        }
    }

    /// 生成一张角色的日常照片。
    func dailyPhoto(
        persona: Persona,
        scene: String,
        emotion: EmotionState? = nil,
        referenceImage: UIImage? = nil
    ) async throws -> Data {
        guard let provider else { throw LLMError.missingAPIKey }

        let sceneKind = Scene.allCases.first { scene.contains($0.displayName) } ?? .selfie
        let prompt = composePrompt(
            persona: persona,
            sceneKind: sceneKind,
            freeform: scene,
            emotion: emotion
        )
        return try await provider.generate(prompt: prompt, aspect: .portrait)
    }

    /// 拼装提示词。顺序很重要：主体 -> 锁脸 -> 场景 -> 镜头 -> 风格 -> 负面。
    private func composePrompt(
        persona: Persona,
        sceneKind: Scene,
        freeform: String,
        emotion: EmotionState?
    ) -> String {
        var parts: [String] = []

        // 1. 主体 + 锁脸锚点（永远放最前，权重最高）
        parts.append("照片里的主角：\(persona.name)。")
        if !persona.presentation.appearanceAnchor.isBlank {
            parts.append(persona.presentation.appearanceAnchor + "。")
        }
        parts.append("必须与描述一致的同一个人，五官、发型、发色、瞳色、服装风格保持一致。")

        // 2. 场景
        parts.append("场景：\(freeform.isBlank ? sceneKind.displayName : freeform)。")

        // 3. 情绪 -> 表情
        if let emotion {
            let face: String
            if emotion.valence > 0.5 && emotion.arousal > 0.5 { face = "笑着，眼睛弯起来" }
            else if emotion.valence > 0.3 { face = "嘴角微微上扬" }
            else if emotion.valence < -0.4 { face = "神情低落，视线下垂" }
            else if emotion.arousal > 0.7 { face = "睁大眼睛，有点惊讶" }
            else { face = "表情平静，看着镜头" }
            parts.append("神情：\(face)。")
        }

        // 4. 机位
        parts.append("构图：\(sceneKind.framing)。")

        // 5. 风格：像真人用手机拍的，而不是精修插画
        parts.append("""
        风格：手机摄影，自然光，轻微噪点，生活感。
        不要：过度磨皮、影楼打光、明显 AI 质感、多余的手指、文字水印。
        """)

        return parts.joined(separator: "\n")
    }

    /// 给一张图配一句台词 —— 让"发照片"这件事变成对话的一部分，
    /// 而不是丢一张图过来就不说话了。
    func caption(
        for persona: Persona,
        scene: String,
        emotion: EmotionState?
    ) async -> String {
        guard let captioner else { return scene }
        let prompt = """
        你是 \(persona.core.name)。\(persona.core.seed.oneLine)
        你说话的方式：\(persona.core.seed.speechStyle)
        \(persona.core.speechQuirks.isEmpty ? "" : "你的口癖：" + persona.core.speechQuirks.joined(separator: "、"))

        你刚拍了一张照片发给他，内容是：\(scene)。
        配一句话，就像发朋友圈或者发给朋友那种。

        要求：一句，不超过 20 字。不要用"分享一张照片"这种说明句。
        不要加引号。不要用 emoji。
        """
        var output = ""
        do {
            let request = LLMRequest(
                messages: [LLMMessage(role: .user, content: prompt)],
                temperature: 1.0,
                maxTokens: 60
            )
            for try await delta in captioner.stream(request) { output += delta }
        } catch {
            return scene
        }
        let clean = ImmersionGuard.scrub(output).clean.trimmed
        return clean.count > 40 ? String(clean.prefix(40)) : clean
    }

    /// 用户发来一张图，让角色"看懂"并回应。
    func describeIncoming(image: UIImage, persona: Persona) async -> String? {
        guard let captioner else { return nil }
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let dataURL = "data:image/jpeg;base64," + data.base64EncodedString()

        let prompt = """
        你是 \(persona.core.name)。对方给你发了一张图片。
        用一句话说出你看到了什么，以及你注意到的一个细节。
        不要客套，不要描述得太完整 —— 真人只会注意到其中一两个点。
        """
        var output = ""
        do {
            let request = LLMRequest(
                messages: [LLMMessage(role: .user, content: prompt, images: [dataURL])],
                temperature: 0.8,
                maxTokens: 120
            )
            for try await delta in captioner.stream(request) { output += delta }
        } catch {
            return nil
        }
        return output.trimmed
    }
}
