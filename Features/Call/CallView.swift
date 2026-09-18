import AetherCore
import SwiftUI

/// 通话界面。
///
/// 和聊天界面共享同一个形象协调器 —— 你在通话里看到的她，
/// 和你在聊天里看到的是同一个人、同一套情绪、同一组动作。
struct CallView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let persona: Persona
    let conversationID: UUID
    let coordinator: AvatarCoordinator

    @State private var session: CallSession?
    @State private var elapsed: Double = 0
    @State private var isSpeaking = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            StageEffectLayer(stage: env.stage)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)

                coordinator.runtime?.makeView()
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(isSpeaking ? 1.02 : 1.0)
                    .animation(.easeInOut(duration: 0.35), value: isSpeaking)

                Spacer(minLength: 8)

                if let transcript = session?.liveTranscript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                } else if let reply = session?.lastReply, !reply.isEmpty {
                    Text(reply)
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .lineLimit(4)
                        .transition(.opacity)
                }

                Spacer()

                controls
            }
            .padding(.vertical, 24)
        }
        .task {
            await env.avatar.activate(persona: persona, settings: env.settings)
            let created = CallSession(store: env.store)
            created.onSpeakingChanged = { speaking in
                isSpeaking = speaking
                if speaking { env.avatar.beginSpeaking() } else { env.avatar.endSpeaking() }
            }
            created.onAvatarEmotion = { emotion in
                env.avatar.apply(emotion: emotion, intensity: 1)
            }
            session = created
            await created.start(with: persona, conversationID: conversationID)
        }
        .onDisappear {
            session?.hangUp()
            env.avatar.endSpeaking()
            env.avatar.shutdown()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(persona.name)
                .font(.system(size: 22, weight: .semibold))
            Text(statusText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusText: String {
        guard let session else { return "" }
        switch session.phase {
        case .ended(let reason): return reason
        case .dialing, .ringing, .connecting: return session.phase.label
        default:
            return timeString(session.duration)
        }
    }

    private var controls: some View {
        HStack(spacing: 46) {
            CallButton(icon: "mic.slash.fill", label: "静音", tint: .white.opacity(0.14)) {
                // 静音实现口：直接停掉识别回路
                session?.hangUp()
            }
            CallButton(icon: "phone.down.fill", label: "挂断", tint: Color(hex: "#FF4D6D")) {
                session?.hangUp()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() }
            }
            CallButton(icon: "speaker.wave.2.fill", label: "免提", tint: .white.opacity(0.14)) {
                // 免提切换由 AVAudioSession 接管，这里留出交互位
            }
        }
        .padding(.bottom, 8)
    }

    private var background: some View {
        let colors = persona.presentation.palette.map { Color(hex: $0) }
        return LinearGradient(
            colors: [
                (colors.first ?? Color(hex: "#8A7BFF")).opacity(0.22),
                Color(uiColor: .systemBackground),
                (colors.last ?? Color(hex: "#FFB4C8")).opacity(0.14),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CallButton: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(tint))
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
