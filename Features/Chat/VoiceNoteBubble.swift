import AetherCore
import SwiftUI
import AVFoundation

/// 语音播放器。
///
/// 播放的时候角色的嘴会跟着动 —— 这是「发语音」和「播放一段音频」的区别。
/// 只允许同时播一条：真人不会同时放两段语音。
@MainActor
@Observable
final class VoiceNotePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceNotePlayer()

    private(set) var playingFileName: String?
    private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// 由界面注入：播音时驱动口型
    var onSpeakingChanged: ((Bool) -> Void)?

    func toggle(fileName: String) {
        if playingFileName == fileName {
            stop()
        } else {
            play(fileName: fileName)
        }
    }

    func play(fileName: String) {
        stop()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Aether/Media").appendingPathComponent(fileName)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Log.voice.error("cannot play \(fileName)")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Log.voice.error("audio session: \(error.localizedDescription)")
        }
        player.delegate = self
        player.prepareToPlay()
        player.play()
        self.player = player
        playingFileName = fileName
        onSpeakingChanged?(true)

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
                if !player.isPlaying { return }
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        if playingFileName != nil {
            onSpeakingChanged?(false)
        }
        playingFileName = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// 语音气泡：波形 + 时长 + 播放进度 + （可选）转写。
struct VoiceNoteBubble: View {
    let attachment: Attachment?
    let isMine: Bool
    @State private var player = VoiceNotePlayer.shared
    @State private var showTranscript = false

    private var fileName: String { attachment?.fileName ?? "" }
    private var isPlaying: Bool { player.playingFileName == fileName }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    player.toggle(fileName: fileName)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isMine ? .white : Color(hex: "#6C5CE7"))
                        .frame(width: 24, height: 24)
                }

                waveform

                Text(durationText)
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(isMine ? .white.opacity(0.85) : .secondary)
            }
            .frame(minWidth: 150)

            if let transcript = attachment?.transcript, !transcript.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showTranscript.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showTranscript ? "text.bubble.fill" : "text.bubble")
                        Text(showTranscript ? "收起" : "转写")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(isMine ? .white.opacity(0.7) : .secondary)
                }
                if showTranscript {
                    Text(transcript)
                        .font(.system(size: 12))
                        .foregroundStyle(isMine ? .white.opacity(0.9) : .secondary)
                        .transition(.opacity)
                }
            }
        }
    }

    private var waveform: some View {
        let peaks = attachment?.waveform ?? Array(repeating: 0.3, count: 24)
        let played = Int(Double(peaks.count) * (isPlaying ? player.progress : 0))
        return HStack(spacing: 2) {
            ForEach(Array(peaks.enumerated()), id: \.offset) { index, peak in
                Capsule()
                    .fill(barColor(index: index, played: played, isMine: isMine))
                    .frame(width: 2.5, height: max(3, CGFloat(peak) * 24))
            }
        }
        .frame(height: 26)
    }

    private func barColor(index: Int, played: Int, isMine: Bool) -> Color {
        let base = isMine ? Color.white : Color(hex: "#6C5CE7")
        return index < played ? base : base.opacity(0.32)
    }

    private var durationText: String {
        let seconds = Int(attachment?.duration ?? 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
