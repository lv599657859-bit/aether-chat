import AetherCore
import SwiftUI

/// 立绘/模型的统一接口。
///
/// 上层（导演、聊天界面、通话界面）只认这套接口，不关心底下是
/// Live2D、VRM 还是「什么素材都没有只好画个光团」。
/// 换渲染方案不动业务代码，这是这个协议存在的全部理由。
@MainActor
protocol AvatarRuntime: AnyObject {
    var kind: AvatarKind { get }
    /// 素材是否已就绪（没就绪时上层会显示降级形态）
    var isReady: Bool { get }
    /// 素材加载失败的原因，仅用于设置页排错，不进聊天界面
    var loadError: String? { get }

    func load(assetName: String?, palette: [String]) async

    /// 情绪 -> 表情/姿态。由 AvatarCoordinator 以 30-60fps 平滑调用。
    func apply(emotion: EmotionState, intensity: Double)

    /// 一次性动作
    func play(action: String, intensity: Double)

    /// 口型（通话/语音播放时）
    func setSpeaking(_ speaking: Bool, mouthOpen: Double)

    func makeView() -> AnyView
}

/// 动作名 -> 各家实现自己的参数映射表。
/// 放在这里是为了让所有运行时对同一个动作名有**一致的情绪意图**。
enum AvatarActionSemantics {
    /// 这个动作大致表达什么情绪（用于没有对应动画时退化为表情）
    static func emotion(for action: String) -> EmotionState? {
        switch action {
        case "smile", "grin": return EmotionState(valence: 0.7, arousal: 0.4, dominance: 0.5, labels: ["笑"])
        case "pout", "sulk": return EmotionState(valence: -0.3, arousal: 0.3, dominance: 0.4, labels: ["闹别扭"])
        case "blush": return EmotionState(valence: 0.6, arousal: 0.7, dominance: 0.3, labels: ["害羞"])
        case "cry": return EmotionState(valence: -0.8, arousal: 0.6, dominance: 0.2, labels: ["难过"])
        case "angry": return EmotionState(valence: -0.7, arousal: 0.85, dominance: 0.8, labels: ["生气"])
        case "surprise": return EmotionState(valence: 0.2, arousal: 0.9, dominance: 0.4, labels: ["惊讶"])
        case "thinking": return EmotionState(valence: 0.1, arousal: 0.25, dominance: 0.5, labels: ["思考"])
        case "lookaway": return EmotionState(valence: -0.1, arousal: 0.35, dominance: 0.35, labels: ["回避"])
        case "sigh": return EmotionState(valence: -0.3, arousal: 0.2, dominance: 0.4, labels: ["无奈"])
        case "shiver": return EmotionState(valence: -0.4, arousal: 0.7, dominance: 0.2, labels: ["发颤"])
        case "leanin": return EmotionState(valence: 0.5, arousal: 0.5, dominance: 0.6, labels: ["靠近"])
        default: return nil
        }
    }

    /// 该动作有没有对应的「姿势位移」含义（供没有骨骼动画的实现做形变）
    static func poseOffset(for action: String) -> CGSize {
        switch action {
        case "leanin": return CGSize(width: 0, height: -8)
        case "stepback": return CGSize(width: 0, height: 6)
        case "tilt": return CGSize(width: -6, height: 0)
        case "nod": return CGSize(width: 0, height: 4)
        case "shakehead": return CGSize(width: 5, height: 0)
        default: return .zero
        }
    }
}
