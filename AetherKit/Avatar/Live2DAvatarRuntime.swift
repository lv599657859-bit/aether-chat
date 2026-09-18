import SwiftUI

/// Live2D Cubism 的接入点。
///
/// 为什么做成桥接协议而不是直接调用 Cubism SDK：
/// Cubism SDK for Native 是闭源且需要 Live2D 公司授权的，不能随本仓库分发。
/// 你有授权后，把 SDK 拖进工程，写一个 30 行的 Bridge 实现这个协议，
/// 整个 app 立刻拥有真正的 2D 立绘演出 —— 上层一行都不用改。
@MainActor
protocol Live2DModelBridge: AnyObject {
    /// 返回是否加载成功。model3.json 的路径由调用方给出。
    func loadModel(at url: URL) -> Bool
    /// 标准 Cubism 参数：ParamAngleX/Y/Z, ParamEyeLOpen, ParamEyeROpen,
    /// ParamMouthOpenY, ParamBodyAngleX/Y/Z, ParamBreath ...
    func setParameter(_ id: String, value: Float)
    /// 动作组（Idle / Tap / Happy / Angry ...）
    func playMotion(group: String, index: Int) -> Bool
    /// 供 SwiftUI 展示的视图（Cubism 的 Metal 视图）
    func makeView() -> AnyView
    var parameterIDs: [String] { get }
}

/// Live2D 运行时。没有 Bridge 时优雅降级为「光核」，不会黑屏。
@MainActor
final class Live2DAvatarRuntime: AvatarRuntime {
    let kind: AvatarKind = .live2D
    private(set) var isReady = false
    private(set) var loadError: String?

    private let bridge: Live2DModelBridge?
    private var fallback = OrbAvatarRuntime()

    private var current = EmotionState.neutral
    private var speaking = false
    private var mouth: Double = 0
    private var breath: Double = 0
    private var blink: Double = 1

    init(bridge: Live2DModelBridge? = nil) {
        self.bridge = bridge
        if bridge == nil {
            loadError = "未接入 Live2D Cubism SDK（需要授权）"
        }
    }

    func load(assetName: String?, palette: [String]) async {
        await fallback.load(assetName: assetName, palette: palette)
        guard let bridge, let assetName, !assetName.isBlank else { return }

        guard let url = Bundle.main.url(forResource: assetName, withExtension: "json")
                ?? Bundle.main.url(forResource: assetName, withExtension: "model3.json") else {
            loadError = "找不到 \(assetName).model3.json"
            return
        }
        isReady = bridge.loadModel(at: url)
        if !isReady { loadError = "模型加载失败：\(assetName)" }
    }

    func apply(emotion: EmotionState, intensity: Double) {
        current = current.blended(with: emotion, t: 0.14)
        guard isReady, let bridge else { return }

        // 情绪 -> Cubism 标准参数。这张表就是「演出」在 2D 上的全部秘密。
        let v = current.valence, a = current.arousal, d = current.dominance
        bridge.setParameter("ParamAngleX", value: Float(v * 20))
        bridge.setParameter("ParamAngleY", value: Float((1 - a) * 10 - 5))
        bridge.setParameter("ParamAngleZ", value: Float(d * 12 - 6))
        bridge.setParameter("ParamBodyAngleX", value: Float(v * 8))
        bridge.setParameter("ParamBodyAngleY", value: Float(a * 6))
        bridge.setParameter("ParamBodyAngleZ", value: Float(d * 10 - 5))
        bridge.setParameter("ParamEyeLOpen", value: Float(blink))
        bridge.setParameter("ParamEyeROpen", value: Float(blink))
        bridge.setParameter("ParamEyeBallX", value: Float(v * 0.6))
        bridge.setParameter("ParamEyeBallY", value: Float(a * 0.4))
        bridge.setParameter("ParamMouthOpenY", value: speaking ? Float(mouth) : Float(a * 0.1))
        bridge.setParameter("ParamMouthForm", value: Float(v))
        bridge.setParameter("ParamBrowLY", value: Float(v * 0.7))
        bridge.setParameter("ParamBrowRY", value: Float(v * 0.7))
        bridge.setParameter("ParamCheek", value: Float(max(0, v - 0.3) * 2))
        bridge.setParameter("ParamBreath", value: Float(breath))
    }

    func play(action: String, intensity: Double) {
        guard isReady, let bridge else {
            fallback.play(action: action, intensity: intensity)
            return
        }
        if !bridge.playMotion(group: action, index: 0) {
            // 没有对应动作就用表情代偿 —— 演出不能因为缺素材就断掉
            if let emo = AvatarActionSemantics.emotion(for: action) {
                apply(emotion: emo, intensity: intensity)
            }
        }
    }

    func setSpeaking(_ speaking: Bool, mouthOpen: Double) {
        self.speaking = speaking
        self.mouth = mouthOpen
    }

    func advance(by seconds: Double) {
        breath += seconds * (0.5 + current.arousal * 0.7)
        blink -= seconds * 0.09
        if blink < -0.15 { blink = 1 }
        blink = blink.clamped(0, 1)
        fallback.apply(emotion: current, intensity: 1)
        fallback.advance(by: seconds)
    }

    func makeView() -> AnyView {
        if isReady, let bridge { return bridge.makeView() }
        return fallback.makeView()
    }

    var status: (ready: Bool, error: String?, params: Int) {
        (isReady, loadError, bridge?.parameterIDs.count ?? 0)
    }
}
