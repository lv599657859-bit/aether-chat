import AetherCore
import SwiftUI

/// 屏幕演出层。
///
/// 雨、雪、樱花、萤火、闪光、故障、暗角 —— 全部由 Canvas 现画，
/// 不依赖任何图片素材和视频文件。这是「有很多演出效果」最划算的实现方式：
/// 一个文件、零资源、随时可调参数，而且不会因为缺素材而降级。
struct StageEffectLayer: View {
    let stage: StageState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                stage.tick()

                if let ambient = stage.ambient, ambient.intensity > 0.02 {
                    draw(effect: ambient.name, intensity: ambient.intensity,
                         context: &context, size: size, time: time)
                }

                for effect in stage.transient where effect.intensity > 0.02 {
                    let fade = fadeCurve(effect: effect)
                    draw(effect: effect.name, intensity: effect.intensity * fade,
                         context: &context, size: size, time: time)
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// 瞬时效果自己淡出，不需要外部管理生命周期。
    private func fadeCurve(effect: StageEffect) -> Double {
        guard let lifetime = effect.lifetime, lifetime > 0 else { return 1 }
        let progress = effect.age / lifetime
        if progress < 0.15 { return progress / 0.15 }
        if progress > 0.7 { return max(0, (1 - progress) / 0.3) }
        return 1
    }

    private func draw(effect: String, intensity: Double, context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        switch effect {
        case "rain":      drawRain(&context, size, time, intensity)
        case "snow":      drawSnow(&context, size, time, intensity)
        case "petals":    drawPetals(&context, size, time, intensity)
        case "fireflies": drawFireflies(&context, size, time, intensity)
        case "firefly":   drawFireflies(&context, size, time, intensity)
        case "sparkle":   drawSparkle(&context, size, time, intensity)
        case "heartbeat": drawHeartbeat(&context, size, time, intensity)
        case "flash":     drawFlash(&context, size, intensity)
        case "glitch":    drawGlitch(&context, size, time, intensity)
        case "vignette":  drawVignette(&context, size, intensity)
        case "night":     drawNight(&context, size, intensity)
        case "sunset":    drawSunset(&context, size, intensity)
        case "sepia":     drawTint(&context, size, Color(red: 0.42, green: 0.32, blue: 0.2), intensity * 0.35)
        case "blur":      drawTint(&context, size, Color(hex: "#8A7BFF"), intensity * 0.12)
        case "crack":     drawGlitch(&context, size, time, intensity * 0.6)
        default:          break
        }
    }

    // MARK: - 天气

    private func drawRain(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let count = Int(90 * intensity)
        for i in 0..<count {
            let seed = Double(i) * 0.618
            let speed = 620.0 + seed.truncatingRemainder(dividingBy: 1) * 480
            let x = (seed * 7919).truncatingRemainder(dividingBy: 1) * size.width
            let y = ((seed * 104729).truncatingRemainder(dividingBy: 1) * size.height + time * speed)
                .truncatingRemainder(dividingBy: size.height + 60) - 30
            let length = 12 + seed.truncatingRemainder(dividingBy: 1) * 14
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - 2.5, y: y + length))
            context.stroke(path, with: .color(.white.opacity(0.28 * intensity)), lineWidth: 1)
        }
    }

    private func drawSnow(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let count = Int(60 * intensity)
        for i in 0..<count {
            let seed = Double(i) * 0.618
            let speed = 40.0 + seed.truncatingRemainder(dividingBy: 1) * 60
            let sway = sin(time * 1.2 + seed * 10) * 18
            let x = (seed * 7919).truncatingRemainder(dividingBy: 1) * size.width + sway
            let y = ((seed * 104729).truncatingRemainder(dividingBy: 1) * size.height + time * speed)
                .truncatingRemainder(dividingBy: size.height + 20)
            let r = 1.5 + seed.truncatingRemainder(dividingBy: 1) * 2.5
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.55 * intensity))
            )
        }
    }

    private func drawPetals(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let count = Int(34 * intensity)
        for i in 0..<count {
            let seed = Double(i) * 0.618
            let speed = 55.0 + seed.truncatingRemainder(dividingBy: 1) * 70
            let sway = sin(time * 0.9 + seed * 8) * 46
            let x = (seed * 7919).truncatingRemainder(dividingBy: 1) * size.width + sway
            let y = ((seed * 104729).truncatingRemainder(dividingBy: 1) * size.height + time * speed)
                .truncatingRemainder(dividingBy: size.height + 30)
            let w = 7 + seed.truncatingRemainder(dividingBy: 1) * 6
            let rect = CGRect(x: x, y: y, width: w, height: w * 0.6)
            var path = Path(roundedRect: rect, cornerRadius: w * 0.3)
            path = path.applying(CGAffineTransform(rotationAngle: CGFloat(sin(time + seed * 6) * 0.9)))
            context.fill(path, with: .color(Color(hex: "#FFC7D9").opacity(0.75 * intensity)))
        }
    }

    private func drawFireflies(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let count = Int(26 * intensity)
        for i in 0..<count {
            let seed = Double(i) * 0.618
            let x = (seed * 7919).truncatingRemainder(dividingBy: 1) * size.width
                + sin(time * 0.6 + seed * 12) * 40
            let y = (seed * 104729).truncatingRemainder(dividingBy: 1) * size.height
                + cos(time * 0.5 + seed * 9) * 30
            let glow = (sin(time * 1.8 + seed * 20) * 0.5 + 0.5) * intensity
            let r = 2.5 + glow * 3.5
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(colors: [Color(hex: "#FFF3B0").opacity(glow), .clear]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 3
                )
            )
        }
    }

    // MARK: - 情绪

    private func drawSparkle(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let count = Int(18 * intensity)
        for i in 0..<count {
            let seed = Double(i) * 0.618
            let phase = (time * 1.4 + seed * 5).truncatingRemainder(dividingBy: 3.0) / 3.0
            let x = (seed * 7919).truncatingRemainder(dividingBy: 1) * size.width
            let y = (seed * 104729).truncatingRemainder(dividingBy: 1) * size.height * 0.8
            let scale = sin(phase * .pi) * 9 * intensity
            guard scale > 0.3 else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x - scale, y: y))
            path.addLine(to: CGPoint(x: x + scale, y: y))
            path.move(to: CGPoint(x: x, y: y - scale))
            path.addLine(to: CGPoint(x: x, y: y + scale))
            context.stroke(path, with: .color(.white.opacity(0.8 * Double(sin(phase * .pi)))), lineWidth: 1.4)
        }
    }

    private func drawHeartbeat(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let beat = (sin(time * 6.0) * 0.5 + 0.5)
        let inset = -20 * beat * intensity
        var path = Path()
        path.addEllipse(in: CGRect(x: inset, y: inset,
                                   width: size.width - inset * 2, height: size.height - inset * 2))
        context.stroke(path, with: .color(Color(hex: "#FF6B8A").opacity(0.35 * beat * intensity)), lineWidth: 3)
    }

    private func drawFlash(_ context: inout GraphicsContext, _ size: CGSize, _ intensity: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.55 * intensity)))
    }

    private func drawGlitch(_ context: inout GraphicsContext, _ size: CGSize, _ time: TimeInterval, _ intensity: Double) {
        let bands = Int(9 * intensity)
        for i in 0..<bands {
            let seed = Double(i) * 1.37
            let y = ((seed * 104729).truncatingRemainder(dividingBy: 1) * size.height
                     + time * 320 * (i % 2 == 0 ? 1 : -1))
                .truncatingRemainder(dividingBy: size.height)
            let h = 2 + seed.truncatingRemainder(dividingBy: 1) * 10
            let offset = sin(time * 22 + seed * 5) * 24 * intensity
            let rect = CGRect(x: offset, y: y, width: size.width, height: h)
            context.fill(Path(rect), with: .color(Color(hex: "#5AF0FF").opacity(0.25 * intensity)))
            context.fill(Path(rect.offsetBy(dx: -offset * 2, dy: 0)),
                         with: .color(Color(hex: "#FF3D7F").opacity(0.18 * intensity)))
        }
    }

    private func drawVignette(_ context: inout GraphicsContext, _ size: CGSize, _ intensity: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(size.width, size.height) * 0.65
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.62 * intensity)]),
                center: center, startRadius: radius * 0.45, endRadius: radius * 1.35
            )
        )
    }

    private func drawNight(_ context: inout GraphicsContext, _ size: CGSize, _ intensity: Double) {
        drawTint(&context, size, Color(hex: "#141B33"), intensity * 0.45)
    }

    private func drawSunset(_ context: inout GraphicsContext, _ size: CGSize, _ intensity: Double) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [Color(hex: "#FF9A6C").opacity(0.35 * intensity), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    private func drawTint(_ context: inout GraphicsContext, _ size: CGSize, _ color: Color, _ opacity: Double) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(opacity.clamped(0, 0.7))))
    }
}
