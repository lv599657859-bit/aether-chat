import AetherCore
import SwiftUI

/// 聊天界面上方的「形象带」。
///
/// 它是整个 app 的门面：一眼看过去，是一个活人在呼吸、眨眼、因为你的话脸红。
/// 高度可折叠 —— 想专心打字就把它收起来，但角色始终在场。
struct AvatarStageView: View {
    let persona: Persona
    let coordinator: AvatarCoordinator
    let stage: StageState
    @Binding var isExpanded: Bool

    private var currentEmotion: EmotionState { coordinator.currentEmotion }

    var body: some View {
        ZStack {
            background
            StageEffectLayer(stage: stage)

            VStack(spacing: 6) {
                Spacer(minLength: 0)

                coordinator.runtime?.makeView()
                    .frame(height: isExpanded ? 200 : 96)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)

                if isExpanded {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(emotionColor)
                            .frame(width: 6, height: 6)
                        Text(currentEmotion.dominantLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .frame(height: isExpanded ? 250 : 130)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { isExpanded.toggle() }
        }
        .animation(.easeInOut(duration: 0.8), value: currentEmotion.valence)
    }

    /// 背景随情绪走：她开心，光就暖一点；她低落，画面就沉下去。
    private var background: some View {
        let valence = (currentEmotion.valence + 1) / 2
        let colors = persona.presentation.palette.map { Color(hex: $0) }
        let base = colors.first ?? Color(hex: "#8A7BFF")
        let accent = colors.count > 1 ? colors[1] : Color(hex: "#FFB4C8")

        return LinearGradient(
            colors: [
                base.opacity(0.10 + valence * 0.16),
                accent.opacity(0.05 + valence * 0.12),
                Color.clear,
            ],
            startPoint: .top, endPoint: .bottom
        )
        .animation(.easeInOut(duration: 1.0), value: currentEmotion.valence)
    }

    private var emotionColor: Color {
        let v = currentEmotion.valence
        if v > 0.5 { return Color(hex: "#FF8FA8") }
        if v > 0.1 { return Color(hex: "#FFC86B") }
        if v > -0.3 { return Color(hex: "#8FD4FF") }
        return Color(hex: "#7A8DA8")
    }
}
