import AetherCore
import SwiftUI

/// 形象协调器。
///
/// 职责有三个：
///   1. 按人格配置挑运行时（3D / 2D / 立绘 / 光核），坏一个就往下退一级，绝不白屏
///   2. 用一个稳定的心跳推进所有动画（不依赖视图刷新率）
///   3. 把情绪向量平滑地喂给运行时 —— 情绪永远不是瞬变，是渐变的
@MainActor
@Observable
final class AvatarCoordinator {
    private(set) var runtime: (any AvatarRuntime)?
    private(set) var currentEmotion: EmotionState = .neutral
    private(set) var degraded = false
    private(set) var degradationNote: String?

    private var heartbeat: Task<Void, Never>?
    private var speaking = false
    private var mouth: Double = 0
    private var mouthTask: Task<Void, Never>?

    /// 3D 运行时的宿主（由视图注入）
    var sceneHost: AvatarSceneHost? {
        didSet { (runtime as? RealityKitAvatarRuntime)?.host = sceneHost }
    }

    func activate(persona: Persona, settings: AppSettings, live2DBridge: Live2DModelBridge? = nil) async {
        heartbeat?.cancel()
        degraded = false
        degradationNote = nil

        var candidate: any AvatarRuntime
        switch persona.presentation.avatarKind {
        case .threeD:
            candidate = RealityKitAvatarRuntime()
        case .live2D:
            candidate = Live2DAvatarRuntime(bridge: live2DBridge)
        case .sprite:
            candidate = SpriteAvatarRuntime()
        case .orb:
            candidate = OrbAvatarRuntime()
        }

        await candidate.load(
            assetName: persona.presentation.avatarAssetName,
            palette: persona.presentation.palette
        )

        // 逐级降级：3D -> 立绘 -> 光核
        if !candidate.isReady, persona.presentation.avatarKind != .orb {
            degradationNote = candidate.loadError
            degraded = true
            Log.stage.info("avatar degraded from \(persona.presentation.avatarKind.rawValue): \(candidate.loadError ?? "-")")

            if persona.presentation.avatarKind == .threeD || persona.presentation.avatarKind == .live2D {
                let sprite = SpriteAvatarRuntime()
                await sprite.load(assetName: persona.presentation.avatarAssetName,
                                  palette: persona.presentation.palette)
                if sprite.isReady { candidate = sprite }
            }
            if !candidate.isReady {
                let orb = OrbAvatarRuntime()
                await orb.load(assetName: nil, palette: persona.presentation.palette)
                candidate = orb
            }
        }

        runtime = candidate
        sceneHost = sceneHost
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeat = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30fps
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                guard let self else { return }
                if let orb = self.runtime as? OrbAvatarRuntime { orb.advance(by: dt) }
                if let sprite = self.runtime as? SpriteAvatarRuntime { sprite.advance(by: dt) }
                if let three = self.runtime as? RealityKitAvatarRuntime { three.advance(by: dt) }
                if let live = self.runtime as? Live2DAvatarRuntime { live.advance(by: dt) }
            }
        }
    }

    func apply(emotion: EmotionState, intensity: Double = 1) {
        currentEmotion = currentEmotion.blended(with: emotion, t: 0.3)
        runtime?.apply(emotion: currentEmotion, intensity: intensity)
    }

    func play(action: String, intensity: Double) {
        runtime?.play(action: action, intensity: intensity)
    }

    // MARK: - 口型

    func beginSpeaking() {
        guard !speaking else { return }
        speaking = true
        runtime?.setSpeaking(true, mouthOpen: 0)
        mouthTask = Task { [weak self] in
            var phase = 0.0
            while !Task.isCancelled {
                guard let self, self.speaking else { return }
                // 简单音节节奏：真人说话也有起伏，不是等幅方波
                phase += 0.28
                let value = (sin(phase) * 0.5 + 0.5) * Double.random(in: 0.6...1.0)
                self.runtime?.setSpeaking(true, mouthOpen: value)
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
    }

    func endSpeaking() {
        speaking = false
        mouthTask?.cancel()
        mouthTask = nil
        runtime?.setSpeaking(false, mouthOpen: 0)
    }

    func shutdown() {
        heartbeat?.cancel()
        heartbeat = nil
        endSpeaking()
    }
}
