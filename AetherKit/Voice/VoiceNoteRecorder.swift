import Foundation
import AVFoundation

/// 语音消息录制。
///
/// 产出三样东西：音频文件、波形（气泡里那排会跳的柱）、以及转写文本。
/// 转写文本属于隐藏层 —— 它进上下文，但默认不显示在气泡上，
/// 除非用户在潜意识层里把「显示语音转写」打开。
@MainActor
@Observable
final class VoiceNoteRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var liveTranscript: String = ""
    private(set) var isCancelled = false

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var transcriber: (any Transcriber)?
    private var fileURL: URL?
    private let media = MediaStore.shared

    var isRecording: Bool { phase == .recording }

    /// 最长录制时长；到点自动结束，避免用户忘记松手录出一个 20 分钟的语音。
    var maxDuration: TimeInterval = 120

    func start(transcriber: (any Transcriber)? = nil, locale: Locale = Locale(identifier: "zh-CN")) async {
        guard phase != .recording else { return }
        isCancelled = false
        levels = []
        elapsed = 0
        liveTranscript = ""

        let granted = await Self.requestMicrophone()
        guard granted else {
            phase = .failed("还没有授予麦克风权限")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let url = try await media.newAudioURL(prefix: "voice")
            fileURL = url

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            phase = .recording

            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                    recorder.updateMeters()
                    let power = recorder.averagePower(forChannel: 0)
                    let level = Self.normalizedPower(power)
                    self.levels.append(level)
                    self.elapsed = recorder.currentTime
                    if self.elapsed >= self.maxDuration { self.stop() }
                }
            }

            if let transcriber {
                self.transcriber = transcriber
                transcribeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        for try await event in transcriber.live(locale: locale) {
                            if case .partial(let text) = event { self.liveTranscript = text }
                            if case .final(let text) = event { self.liveTranscript = text }
                        }
                    } catch { /* 转写失败不影响录音本身 */ }
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 结束并返回可发送的附件。
    func stop() -> Attachment? {
        guard phase == .recording, let recorder, let url = fileURL else { return nil }
        phase = .finishing
        let duration = recorder.currentTime
        recorder.stop()
        meterTask?.cancel()
        transcribeTask?.cancel()
        meterTask = nil
        transcribeTask = nil
        self.recorder = nil

        // 太短 = 误触，直接丢弃
        guard duration > 0.6 else {
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            return nil
        }

        let transcript = liveTranscript
        phase = .idle

        return Attachment(
            kind: .audio,
            fileName: url.lastPathComponent,
            duration: duration,
            waveform: Self.compact(levels),
            transcript: transcript.isBlank ? nil : transcript
        )
    }

    func cancel() {
        isCancelled = true
        meterTask?.cancel()
        transcribeTask?.cancel()
        recorder?.stop()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        phase = .idle
        levels = []
        elapsed = 0
        liveTranscript = ""
    }

    /// 音强 -> 0...1。分贝是对数刻度，直接线性映射会让小声全是 0。
    private static func normalizedPower(_ power: Float) -> Float {
        guard power > -60 else { return 0.02 }
        let normalized = (Double(power) + 60) / 60
        return Float(normalized.clamped(0, 1))
    }

    /// 把整段录音的采样点压成固定根数，供气泡绘制。
    private static func compact(_ levels: [Float], buckets: Int = 36) -> [Float] {
        guard levels.count > buckets else { return levels }
        let size = levels.count / buckets
        return (0..<buckets).map { index in
            let slice = levels[(index * size)..<min(levels.count, (index + 1) * size)]
            return slice.max() ?? 0
        }
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
