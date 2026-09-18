import SwiftUI

/// 光核。
///
/// 这是「什么素材都没有」时的降级形态 —— 但它不是丑的占位符。
/// 一个会呼吸、会随情绪变色、会因惊讶而颤动的光团，本身就能承载演出：
/// 用户第一次打开 app 时看到的不是空白，是一个正在呼吸的活物。
@MainActor
final class OrbAvatarRuntime: AvatarRuntime {
    let kind: AvatarKind = .orb
    private(set) var isReady = true
    private(set) var loadError: String?

    private var palette: [String] = ["#8A7BFF", "#FFB4C8"]
    private var current = EmotionState.neutral
    private var target = EmotionState.neutral
    private var speaking = false
    private var mouth: Double = 0
    private var pulse: Double = 0
    private var breathPhase: Double = 0

    func load(assetName: String?, palette: [String]) async {
        if !palette.isEmpty { self.palette = palette }
    }

    func apply(emotion: EmotionState, intensity: Double) {
        target = emotion
        // 平滑：光是不会瞬间变色的
        current = current.blended(with: target, t: 0.16)
    }

    func play(action: String, intensity: Double) {
        pulse = max(pulse, intensity)
        if let emo = AvatarActionSemantics.emotion(for: action) {
            target = emo
        }
    }

    func setSpeaking(_ speaking: Bool, mouthOpen: Double) {
        self.speaking = speaking
        self.mouth = mouthOpen
    }

    func makeView() -> AnyView {
        AnyView(OrbAvatarView(runtime: self))
    }

    // 供视图读取
    var snapshot: (emotion: EmotionState, palette: [String], breath: Double, pulse: Double, speaking: Bool, mouth: Double) {
        (current, palette, breathPhase, pulse, speaking, mouth)
    }

    func advance(by seconds: Double) {
        breathPhase += seconds * (0.6 + current.arousal * 0.8)
        pulse *= 0.92
        if !speaking { mouth *= 0.85 }
    }
}

struct OrbAvatarView: View {
    let runtime: OrbAvatarRuntime

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let snap = runtime.snapshot
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.32
                let breath = 1 + sin(snap.breath * 2) * 0.04 * (1 + snap.emotion.arousal)
                let radius = base * breath * (1 + snap.pulse * 0.12)

                let warm = Color(hex: snap.palette.first ?? "#8A7BFF")
                let cool = Color(hex: snap.palette.count > 1 ? snap.palette[1] : "#FFB4C8")
                let tint = warm.mix(with: cool, amount: (snap.emotion.valence + 1) / 2)

                // 外晕
                for i in stride(from: 3, through: 1, by: -1) {
                    let r = radius * (1 + Double(i) * 0.22)
                    let opacity = 0.06 / Double(i)
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .color(tint.opacity(opacity))
                    )
                }

                // 本体
                let body = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2))
                context.fill(body, with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.95), tint.opacity(0.35)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                ))

                // 高光（会随呼吸轻微移动）
                let hlOffset = sin(snap.breath) * radius * 0.12
                let hl = Path(ellipseIn: CGRect(
                    x: center.x - radius * 0.45 + hlOffset,
                    y: center.y - radius * 0.5,
                    width: radius * 0.5, height: radius * 0.38
                ))
                context.fill(hl, with: .color(.white.opacity(0.25)))

                // 说话时的口型环
                if snap.speaking {
                    let mr = radius * (0.35 + snap.mouth * 0.4)
                    let mouthPath = Path(ellipseIn: CGRect(x: center.x - mr, y: center.y + radius * 0.25,
                                                           width: mr * 2, height: mr * 0.8))
                    context.stroke(mouthPath, with: .color(.white.opacity(0.35)), lineWidth: 2)
                }

                // 情绪标签（低调地浮在下方）
                _ = t
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }

    func mix(with other: Color, amount: Double) -> Color {
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let k = CGFloat(amount.clamped(0, 1))
        return Color(red: Double(ar + (br - ar) * k),
                     green: Double(ag + (bg - ag) * k),
                     blue: Double(ab + (bb - ab) * k))
    }
}
