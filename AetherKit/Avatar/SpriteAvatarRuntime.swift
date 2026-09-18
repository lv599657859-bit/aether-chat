import SwiftUI

/// 2D 立绘运行时。
///
/// 素材约定（放进 Assets/Portraits/，缺哪张就用哪张的兜底）：
///   <name>_base.png      基础立绘
///   <name>_eyes_open.png 睁眼
///   <name>_eyes_half.png 半闭
///   <name>_eyes_closed.png 闭眼
///   <name>_mouth_0..3.png  口型四帧
///   <name>_blush.png     脸红叠加层（可选）
///
/// 没有骨骼也能演出：呼吸靠缩放、眨眼靠切图、脸红靠叠加、惊讶靠位移。
/// 这是成本最低、覆盖率最高的一条路 —— 一张立绘就能让角色活过来。
@MainActor
final class SpriteAvatarRuntime: AvatarRuntime {
    let kind: AvatarKind = .sprite
    private(set) var isReady = false
    private(set) var loadError: String?

    private var name: String = ""
    private var hasLayers = false

    private var current = EmotionState.neutral
    private var poseOffset: CGSize = .zero
    private var pulse: Double = 0
    private var breath: Double = 0
    private var nextBlink: Double = 2
    private var blinking: Double = 0
    private var speaking = false
    private var mouthFrame: Int = 0

    func load(assetName: String?, palette: [String]) async {
        guard let assetName, !assetName.isBlank else {
            loadError = "未指定立绘素材"
            isReady = false
            return
        }
        name = assetName
        isReady = UIImage(named: "\(assetName)_base") != nil
        hasLayers = isReady && UIImage(named: "\(assetName)_eyes_open") != nil
        if !isReady { loadError = "找不到 \(assetName)_base" }
    }

    func apply(emotion: EmotionState, intensity: Double) {
        current = current.blended(with: emotion, t: 0.14)
    }

    func play(action: String, intensity: Double) {
        pulse = max(pulse, intensity)
        let offset = AvatarActionSemantics.poseOffset(for: action)
        poseOffset = CGSize(width: poseOffset.width + offset.width, height: poseOffset.height + offset.height)
        if let emo = AvatarActionSemantics.emotion(for: action) {
            current = current.blended(with: emo, t: 0.5)
        }
    }

    func setSpeaking(_ speaking: Bool, mouthOpen: Double) {
        self.speaking = speaking
        mouthFrame = Int(mouthOpen.clamped(0, 0.999) * 4)
    }

    func advance(by seconds: Double) {
        breath += seconds * (0.5 + current.arousal * 0.6)
        poseOffset.width *= 0.88
        poseOffset.height *= 0.88
        pulse *= 0.9

        nextBlink -= seconds
        if nextBlink <= 0 {
            blinking = 0.22
            nextBlink = Double.random(in: 2.4...5.6) - current.arousal
        }
        if blinking > 0 { blinking -= seconds }
    }

    func makeView() -> AnyView {
        AnyView(SpriteAvatarView(runtime: self))
    }

    var snapshot: (name: String, hasLayers: Bool, emotion: EmotionState, offset: CGSize, breath: Double, pulse: Double, blinking: Bool, speaking: Bool, mouth: Int) {
        (name, hasLayers, current, poseOffset, breath, pulse, blinking > 0, speaking, mouthFrame)
    }
}

struct SpriteAvatarView: View {
    let runtime: SpriteAvatarRuntime

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let snap = runtime.snapshot
            ZStack {
                if snap.hasLayers {
                    Image("\(snap.name)_base")
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(1 + sin(snap.breath * 2) * 0.012)
                        .offset(x: snap.offset.width, y: snap.offset.height)
                        .overlay {
                            Image(snap.blinking ? "\(snap.name)_eyes_closed" : "\(snap.name)_eyes_open")
                                .resizable()
                                .scaledToFit()
                            if snap.emotion.valence > 0.45 && snap.emotion.arousal > 0.5 {
                                Image("\(snap.name)_blush")
                                    .resizable()
                                    .scaledToFit()
                                    .opacity((snap.emotion.valence - 0.45) * 2.2)
                            }
                        }
                } else {
                    // 素材缺失时的优雅降级 —— 温柔地提示，而不是报错
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.rectangle")
                            .font(.system(size: 36, weight: .thin))
                        Text("立绘素材缺失")
                            .font(.footnote)
                        Text("\(snap.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .animation(.easeOut(duration: 0.2), value: snap.blinking)
        }
    }
}
