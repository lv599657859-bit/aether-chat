import Foundation
import Speech
import AVFoundation

enum TranscriptEvent: Sendable {
    case partial(String)
    case final(String)
    case failed(String)
}

protocol Transcriber: AnyObject, Sendable {
    var id: String { get }
    /// 实时转写：麦克风流进来，文字流出去。
    func live(locale: Locale) -> AsyncThrowingStream<TranscriptEvent, Error>
    /// 已有音频文件转写（语音消息）
    func transcribeFile(at url: URL, locale: Locale) async throws -> String
    func stop()
}

/// 系统语音识别。免费、离线（设备支持时）、中文效果好。
final class SystemTranscriber: Transcriber, @unchecked Sendable {
    let id = "system"

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    func live(locale: Locale) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let authorized = await Self.requestAuthorization()
                guard authorized else {
                    continuation.yield(.failed("还没有授予语音识别权限"))
                    continuation.finish()
                    return
                }
                guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                    continuation.yield(.failed("这台设备暂时无法识别中文"))
                    continuation.finish()
                    return
                }

                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true, options: .notifyOthersOnDeactivation)

                    let request = SFSpeechAudioBufferRecognitionRequest()
                    request.shouldReportPartialResults = true
                    if recognizer.supportsOnDeviceRecognition {
                        request.requiresOnDeviceRecognition = true
                    }
                    self.request = request

                    let input = self.engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    input.removeTap(onBus: 0)
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                        request.append(buffer)
                    }
                    self.engine.prepare()
                    try self.engine.start()

                    self.task = recognizer.recognitionTask(with: request) { result, error in
                        if let result {
                            let text = result.bestTranscription.formattedString
                            continuation.yield(result.isFinal ? .final(text) : .partial(text))
                            if result.isFinal { continuation.finish() }
                        }
                        if let error {
                            continuation.yield(.failed(error.localizedDescription))
                            continuation.finish()
                        }
                    }
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    func transcribeFile(at url: URL, locale: Locale) async throws -> String {
        let authorized = await Self.requestAuthorization()
        guard authorized else { throw LLMError.missingAPIKey }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw LLMError.empty }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// 云端转写（Whisper 系）。识别率更高，尤其在有口音或嘈杂环境下。
final class CloudTranscriber: Transcriber, @unchecked Sendable {
    let id = "cloud"

    private let baseURL: URL
    private let apiKey: String
    private let model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.model = model
    }

    func live(locale: Locale) -> AsyncThrowingStream<TranscriptEvent, Error> {
        // 云端方案是「录完再传」，没有真正的流式增量。
        // 所以通话场景默认用系统识别，云端只做语音消息的离线转写。
        AsyncThrowingStream { continuation in
            continuation.yield(.failed("云端转写不支持实时流，请使用系统识别"))
            continuation.finish()
        }
    }

    func transcribeFile(at url: URL, locale: Locale) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let boundary = "----Aether\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let audio = try Data(contentsOf: url)
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw LLMError.empty }
        return text
    }

    func stop() {}
}
