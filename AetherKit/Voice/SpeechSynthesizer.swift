import Foundation
import AVFoundation

enum SpeechEvent: Sendable {
    case started
    /// 正在念的字符区间（用于逐字高亮）
    case range(NSRange)
    /// 0...1 播放进度（用于口型与波形）
    case progress(Double)
    case finished
    case failed(String)
}

protocol SpeechSynthesizer: AnyObject, Sendable {
    var id: String { get }
    func speak(_ text: String, profile: VoiceProfile) -> AsyncThrowingStream<SpeechEvent, Error>
    func stop()
}

/// 系统 TTS。零成本、离线可用、延迟最低。
/// 缺点也明显：音色是系统音，不能真正复刻角色声线。
/// 所以它的定位是「默认可用 + 云端不可用时的兜底」。
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizer, @unchecked Sendable {
    let id = "system"
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, profile: VoiceProfile) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let clean = SystemSpeechSynthesizer.strippable(text)
            guard !clean.isBlank else {
                continuation.yield(.finished)
                continuation.finish()
                return
            }
            let utterance = AVSpeechUtterance(string: clean)
            if let voiceID = profile.systemVoiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
                utterance.voice = voice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.6 + profile.rate * 0.7)
            utterance.pitchMultiplier = profile.pitch
            utterance.volume = profile.volume
            utterance.postUtteranceDelay = 0.05

            let delegate = SpeechDelegate(continuation: continuation, total: clean.count)
            self.delegate = delegate
            synthesizer.delegate = delegate
            continuation.onTermination = { [weak self] _ in
                self?.synthesizer.stopSpeaking(at: .immediate)
            }
            continuation.yield(.started)
            synthesizer.speak(utterance)
        }
    }

    private var delegate: SpeechDelegate?

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 演出标记不能念出来。
    static func strippable(_ text: String) -> String {
        text.replacingOccurrences(
            of: "⟦[^⟧]*⟧", with: "", options: .regularExpression
        ).trimmed
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    let total: Int

    init(continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation, total: Int) {
        self.continuation = continuation
        self.total = total
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        continuation.yield(.range(characterRange))
        if total > 0 {
            continuation.yield(.progress(Double(characterRange.location + characterRange.length) / Double(total)))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation.yield(.finished)
        continuation.finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation.finish()
    }
}

/// 云端 TTS。音色由 timbrePrompt 描述 —— 这是「复刻角色声线」的入口。
final class CloudSpeechSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    let id = "cloud"

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private var player: AVAudioPlayer?

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.model = model
    }

    func speak(_ text: String, profile: VoiceProfile) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
                    let clean = SystemSpeechSynthesizer.strippable(text)
                    guard !clean.isBlank else {
                        continuation.yield(.finished)
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: baseURL.appendingPathComponent("audio/speech"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    var payload: [String: Any] = [
                        "model": model,
                        "input": clean,
                        "voice": profile.systemVoiceID ?? "alloy",
                        "response_format": "mp3",
                        "speed": 0.85 + Double(profile.rate) * 0.5,
                    ]
                    if !profile.timbrePrompt.isBlank {
                        payload["instructions"] = profile.timbrePrompt
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw LLMError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "")
                    }

                    let player = try AVAudioPlayer(data: data)
                    player.volume = profile.volume
                    player.prepareToPlay()
                    self.player = player
                    continuation.yield(.started)
                    player.play()

                    while player.isPlaying {
                        if Task.isCancelled {
                            player.stop()
                            continuation.finish()
                            return
                        }
                        if player.duration > 0 {
                            continuation.yield(.progress(player.currentTime / player.duration))
                        }
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
