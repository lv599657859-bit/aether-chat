import Foundation
import UIKit
import AVFoundation

/// 导演。
///
/// 模型说的是「她现在很害羞」，导演决定：
///   - 立绘要做几级脸红、眼睛要不要躲开
///   - 气泡要不要抖
///   - 手机上要不要震一下
///   - 背景要不要落一场樱花
///   - 这句话前面要不要停一秒
///
/// 这一层是「演出效果」这个词真正落地的地方，也是模型与渲染之间唯一的收口。
@MainActor
final class PerformanceDirector {
    private let stage: StageState
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var audioPlayers: [String: AVAudioPlayer] = [:]
    private var intensityScale: Double = 0.6

    init(stage: StageState) {
        self.stage = stage
        haptics.prepare()
    }

    func configure(intensityScale: Double, reduceMotion: Bool) {
        self.intensityScale = intensityScale
        stage.reduceMotion = reduceMotion
    }

    /// 消费一条演出指令。
    func dispatch(_ cue: PerformanceCue, personaID: UUID, avatar: AvatarCoordinator?) {
        let amount = stage.scaled(cue.intensity, by: intensityScale)
        guard amount > 0.02 || cue.channel == .pacing else { return }

        switch cue.channel {
        case .avatar:
            avatar?.play(action: cue.name, intensity: amount)

        case .stage:
            let ambientNames: Set<String> = ["rain", "snow", "night", "sepia", "blur", "wind"]
            stage.apply(StageEffect(
                name: cue.name,
                intensity: amount,
                lifetime: ambientNames.contains(cue.name) ? nil : 3.0,
                isAmbient: ambientNames.contains(cue.name)
            ))

        case .bubble:
            break   // 气泡效果由消息自己根据 cues 渲染

        case .audio:
            playAudio(named: cue.name, volume: Float(amount))

        case .haptic:
            fireHaptic(cue.name, intensity: amount)

        case .camera:
            stage.pushCamera(cue.name)

        case .pacing:
            break   // 节拍由 orchestrator 处理
        }
    }

    // MARK: - 触感

    private func fireHaptic(_ name: String, intensity: Double) {
        guard !stage.reduceMotion else { return }
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch name {
        case "heavy", "rigid": style = .rigid
        case "medium", "warning": style = .medium
        case "soft": style = .soft
        default: style = .light
        }
        if name == "success" {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        if name == "warning" {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: CGFloat(intensity.clamped(0.2, 1)))
    }

    /// 由表情驱动的一次轻震 —— 用在「她说到关键处」。
    func pulse(intensity: Double) {
        fireHaptic("light", intensity: intensity)
    }

    // MARK: - 环境音

    private func playAudio(named name: String, volume: Float) {
        // 音频素材不随包分发（体积与版权原因）。把同名 .m4a/.mp3 放进
        // Bundle/Audio/ 下即可自动生效；缺失时优雅降级为静音 + 一次轻震。
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Audio")
                ?? Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Audio")
        else {
            Log.stage.debug("audio asset missing: \(name)")
            return
        }
        if let existing = audioPlayers[name] {
            existing.volume = volume
            existing.numberOfLoops = name.hasSuffix("_loop") ? -1 : 0
            existing.play()
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = volume
        player.numberOfLoops = name.hasSuffix("_loop") ? -1 : 0
        player.prepareToPlay()
        player.play()
        audioPlayers[name] = player
    }

    func stopAmbientAudio() {
        audioPlayers.values.forEach { $0.stop() }
        audioPlayers.removeAll()
    }

    // MARK: - 情绪 -> 舞台

    /// 情绪本身也是一场演出：高激动度会让画面轻微呼吸，低愉悦度会压暗边缘。
    func stageForEmotion(_ emotion: EmotionState) {
        let arousal = stage.scaled(emotion.arousal, by: intensityScale)
        if emotion.valence < -0.5 && arousal > 0.5 {
            stage.setAmbient(name: "vignette", intensity: 0.5)
        } else if stage.ambient?.name == "vignette" && emotion.valence > -0.2 {
            stage.clearAmbient()
        }
    }
}
