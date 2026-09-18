import AetherCore
import Foundation
import SwiftUI

/// 一块正在下的雨，或者一场正在落的樱花。
struct StageEffect: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var intensity: Double
    var startedAt: Date = Date()
    /// nil 表示常驻，直到被新的舞台指令替换
    var lifetime: TimeInterval? = 12
    /// 环境类特效（雨、夜、风）会常驻，情绪类（闪光、心跳）会自己退场
    var isAmbient: Bool = false

    var age: TimeInterval { Date().timeIntervalSince(startedAt) }
    var isExpired: Bool { lifetime.map { age > $0 } ?? false }
}

/// 舞台。
///
/// 用户要求「有很多的演出效果」。演出不是一个特效开关，而是**有状态的舞台**：
/// 下雨了就是真的在下雨，会持续到你切到下个场景；而一次脸红只持续两秒。
/// 这层的职责就是区分这两类，并在两者之间做覆盖与叠加的策略。
@MainActor
@Observable
final class StageState {
    /// 常驻环境（雨 / 夜 / 咖啡馆底噪）
    private(set) var ambient: StageEffect?
    /// 瞬时效果队列
    private(set) var transient: [StageEffect] = []
    /// 当前镜头
    private(set) var camera: String?
    /// 正在播放的环境音名
    private(set) var ambienceTrack: String?

    var reduceMotion = false

    func apply(_ effect: StageEffect) {
        if effect.isAmbient {
            ambient = effect
            if effect.name == "night" || effect.name == "rain" || effect.name == "blur" {
                ambienceTrack = effect.name
            }
        } else {
            transient.removeAll { $0.name == effect.name }
            transient.append(effect)
        }
    }

    func setAmbient(name: String, intensity: Double) {
        apply(StageEffect(name: name, intensity: intensity, lifetime: nil, isAmbient: true))
    }

    func clearAmbient() {
        ambient = nil
        ambienceTrack = nil
    }

    func pushCamera(_ move: String) {
        camera = move
    }

    /// 每帧由视图调用：清理过期效果。
    func tick() {
        let before = transient.count
        transient.removeAll { $0.isExpired }
        if transient.count != before { return }
    }

    /// 按演出强度缩放：设置里调低，所有特效一起变克制。
    func scaled(_ intensity: Double, by global: Double) -> Double {
        reduceMotion ? 0 : (intensity * global).clamped(0, 1)
    }
}
