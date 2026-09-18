import Foundation
import AVFoundation
import UIKit

/// 一次通话。
///
/// 和发消息最大的差别是**实时性和打断**：
///   - 她说话说到一半，你开口了 —— 她必须停下来听（barge-in）
///   - 她停顿、思考、犹豫 —— 沉默也是表演的一部分，不能一沉默就催
///   - 挂断之后，这通电话要变成一条能被后续对话引用的记忆
///
/// 状态机刻意做得显式：真实通话里最容易出的 bug 就是状态错乱（又听又说）。
@MainActor
@Observable
final class CallSession {
    enum Phase: Equatable {
        case idle
        case dialing          // 拨号中
        case ringing          // 对方那边在响
        case connecting
        case listening        // 你在说
        case thinking         // 她在想
        case speaking         // 她在说
        case ended(String)    // 挂断，附原因

        var isLive: Bool {
            switch self {
            case .idle, .ended: return false
            default: return true
            }
        }

        var label: String {
            switch self {
            case .idle: return ""
            case .dialing: return "正在拨号"
            case .ringing: return "等待接听"
            case .connecting: return "接通中"
            case .listening: return "正在听你说"
            case .thinking: return "…"
            case .speaking: return "在说话"
            case .ended(let reason): return reason
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var liveTranscript: String = ""
    private(set) var lastReply: String = ""
    private(set) var inputLevel: Double = 0

    /// 通话结束后写进会话的转写记录（隐藏层的主体）
    private(set) var transcript: [(speaker: String, text: String)] = []

    private var persona: Persona?
    private var conversationID: UUID?
    private let synthesizer: any SpeechSynthesizer
    private let transcriber: any Transcriber
    private let store: WorldStore
    private let orchestrator: ChatOrchestrator

    private var engine: AVAudioEngine?
    private var meterTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var bargeInMonitor: Task<Void, Never>?

    /// 打断判定：连续多久超过阈值才算「真的在说话」
    private let bargeInThreshold: Float = -28
    private let bargeInHold: TimeInterval = 0.35
    private var loudSince: Date?

    /// 由界面注入，用于驱动口型与头像动效
    var onSpeakingChanged: ((Bool) -> Void)?
    var onAvatarEmotion: ((EmotionState) -> Void)?

    init(
        store: WorldStore = .shared,
        synthesizer: (any SpeechSynthesizer)? = nil,
        transcriber: (any Transcriber)? = nil
    ) {
        self.store = store
        self.orchestrator = ChatOrchestrator(store: store)
        let key = Keychain.get("llm.apiKey") ?? ""
        self.synthesizer = synthesizer ?? (key.isEmpty
            ? SystemSpeechSynthesizer()
            : CloudSpeechSynthesizer(baseURL: "https://api.openai.com/v1", apiKey: key, model: "tts-1"))
        self.transcriber = transcriber ?? SystemTranscriber()
    }

    // MARK: - 拨号

    func start(with persona: Persona, conversationID: UUID) async {
        guard !phase.isLive else { return }
        self.persona = persona
        self.conversationID = conversationID
        transcript = []
        lastReply = ""
        liveTranscript = ""
        duration = 0

        phase = .dialing
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard phase.isLive else { return }

        phase = .ringing
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 1.8...3.6) * 1_000_000_000))
        guard phase.isLive else { return }

        phase = .connecting
        do {
            try await configureAudio()
        } catch {
            finish(reason: "无法启动音频")
            return
        }
        phase = .listening
        startDurationTimer()
        startMetering()
        startListening()

        // 她先开口。真人接起电话不会沉默等你。
        await say(opener: true)
    }

    func hangUp() {
        guard phase.isLive else { return }
        speakTask?.cancel()
        synthesizer.stop()
        finish(reason: "通话结束")
    }

    private func finish(reason: String) {
        loopTask?.cancel(); loopTask = nil
        meterTask?.cancel(); meterTask = nil
        durationTask?.cancel(); durationTask = nil
        bargeInMonitor?.cancel(); bargeInMonitor = nil
        speakTask?.cancel(); speakTask = nil
        transcriber.stop()
        synthesizer.stop()
        onSpeakingChanged?(false)

        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        phase = .ended(reason)
        Task { await writeCallLog() }
    }

    // MARK: - 音频

    private func configureAudio() async throws {
        let granted = await VoiceNoteRecorder.requestMicrophone()
        guard granted else { throw LLMError.missingAPIKey }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(frames))
            let db = 20 * log10(max(rms, 1e-7))
            Task { @MainActor [weak self] in self?.handleLevel(db) }
        }
        engine.prepare()
        try engine.start()
    }

    private func startMetering() {
        // 电平处理已经在 tap 回调里，这里只负责把 UI 的电平值衰减回 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.inputLevel *= 0.75
            }
        }
    }

    private func handleLevel(_ db: Float) {
        let normalized = ((Double(db) + 60) / 60).clamped(0, 1)
        inputLevel = max(inputLevel, normalized)

        // 打断检测：她说的时候你在说话，她就得停下来
        guard case .speaking = phase else {
            loudSince = nil
            return
        }
        if db > bargeInThreshold {
            if loudSince == nil { loudSince = Date() }
            if let since = loudSince, Date().timeIntervalSince(since) >= bargeInHold {
                interrupt()
            }
        } else {
            loudSince = nil
        }
    }

    private func interrupt() {
        guard case .speaking = phase else { return }
        loudSince = nil
        speakTask?.cancel()
        synthesizer.stop()
        onSpeakingChanged?(false)
        phase = .listening
        Log.voice.info("barge-in: user interrupted")
    }

    // MARK: - 听

    private func startListening() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.transcriber.live(locale: Locale(identifier: "zh-CN")) {
                    if Task.isCancelled { return }
                    switch event {
                    case .partial(let text):
                        if case .listening = self.phase { self.liveTranscript = text }
                    case .final(let text):
                        guard !text.isBlank else { continue }
                        self.liveTranscript = text
                        await self.respond(to: text)
                    case .failed(let reason):
                        Log.voice.error("transcribe failed: \(reason)")
                    }
                }
            } catch {
                Log.voice.error("listen loop error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 说

    private func respond(to userText: String) async {
        guard phase.isLive else { return }
        transcript.append((speaker: "我", text: userText))
        liveTranscript = ""
        phase = .thinking

        var reply = ""
        var cues: [PerformanceCue] = []

        let stream = orchestrator.send(text: userText, in: conversationID ?? UUID())
        for await event in stream {
            switch event {
            case .partial(let text, _):
                reply = text
            case .actions(_, let batch):
                cues.append(contentsOf: batch)
            case .segment(let message):
                reply = message.text
                if let emotion = message.emotion { onAvatarEmotion?(emotion) }
            case .failed(let reason):
                Log.voice.error("call reply failed: \(reason)")
            default:
                break
            }
        }

        guard !reply.isBlank else {
            phase = .listening
            return
        }
        await speak(reply, cues: cues)
    }

    private func say(opener: Bool) async {
        guard phase.isLive else { return }
        phase = .thinking
        let openerText = opener
            ? "（电话接通了，你先开口。用角色自己的方式打个招呼，一句话就够，别客套。）"
            : ""
        await speak(openerText.isEmpty ? "……" : openerText, cues: [], isPrompt: true)
    }

    private func speak(_ text: String, cues: [PerformanceCue], isPrompt: Bool = false) async {
        guard phase.isLive, let persona else { return }

        var spoken = text
        if isPrompt {
            // 开场白：让模型现场生成，而不是念提示词
            spoken = await generateOpener()
        }
        guard !spoken.isBlank else {
            phase = .listening
            return
        }

        lastReply = spoken
        transcript.append((speaker: persona.name, text: spoken))
        phase = .speaking
        // 电话里没有气泡抖动，但表情和动作照样要有
        for cue in cues where cue.channel == .avatar {
            if let emotion = AvatarActionSemantics.emotion(for: cue.name) {
                onAvatarEmotion?(emotion)
            }
        }
        onSpeakingChanged?(true)

        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.synthesizer.speak(spoken, profile: persona.presentation.voice) {
                    if Task.isCancelled { return }
                    if case .finished = event { break }
                }
            } catch {
                Log.voice.error("tts failed: \(error.localizedDescription)")
            }
            guard !Task.isCancelled else { return }
            self.onSpeakingChanged?(false)
            if self.phase.isLive { self.phase = .listening }
        }
    }

    private func generateOpener() async -> String {
        guard let persona, let conversationID else { return "喂？" }
        let settings = await store.currentSettings()
        let history = await store.messages(in: conversationID, limit: 20)
        let engine = ContextEngine(embedder: ProviderHub.shared.embedder)
        let conversation = await store.conversation(conversationID)
        let memories = await store.memories(stream: persona.memoryStreamID)
        let canon = await store.bundlesFor(persona.id)
        let edge = await store.edge(from: persona.id, to: nil)

        var workingSet = await engine.workingSet(
            persona: persona,
            conversation: conversation ?? .direct(with: persona.id, title: persona.name),
            history: history,
            memories: memories,
            canon: canon,
            edge: edge,
            settings: settings,
            userInput: "（电话接通）"
        )
        workingSet.systemPrompt += """

        【场景】你们正在打电话。你接起了电话，或者你拨出去对方接了。
        说第一句话。一句话，口语，像真的在打电话那样。
        可以有背景音（你在哪里、在做什么），可以有点意外或者理所当然。
        不要用"喂，你好"这种客服式开场。
        """
        workingSet.messages[0] = LLMMessage(role: .system, content: workingSet.systemPrompt)

        var output = ""
        do {
            let request = LLMRequest(
                messages: workingSet.messages,
                temperature: settings.temperature,
                maxTokens: 120,
                model: settings.chatModel
            )
            for try await delta in ProviderHub.shared.llm.stream(request) { output += delta }
        } catch {
            return "喂？"
        }
        let parsed = CueParser.parse(output)
        return parsed.display.trimmed.isEmpty ? "喂？" : parsed.display.trimmed
    }

    // MARK: - 计时与落库

    private func startDurationTimer() {
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.phase.isLive else { return }
                self.duration += 1
            }
        }
    }

    private func writeCallLog() async {
        guard let conversationID, let persona, duration > 1 else { return }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let lengthText = minutes > 0 ? "\(minutes) 分 \(seconds) 秒" : "\(seconds) 秒"

        let transcriptText = transcript.map { "\($0.speaker)：\($0.text)" }.joined(separator: "\n")
        var message = Message(
            conversationID: conversationID,
            authorID: persona.id,
            role: .persona,
            kind: .callLog,
            text: "通话 \(lengthText)"
        )
        message.attachments = [
            Attachment(kind: .file, fileName: "call.txt", duration: duration, transcript: transcriptText)
        ]
        message.hidden.notes = ["通话转写已存入上下文"]
        await store.append(message)

        // 电话比打字更亲密，它应该真的改变关系
        var edge = await store.edge(from: persona.id, to: nil)
        edge.affinity = (edge.affinity + 0.04).clamped(-1, 1)
        edge.familiarity = (edge.familiarity + 0.05).clamped(0, 1)
        edge.lastInteractionAt = Date()
        edge.milestones.append(.init(label: "第一次通话", at: Date(), note: lengthText))
        edge.milestones = Array(edge.milestones.suffix(20))
        edge.reevaluateKind()
        await store.upsert(edge)
    }
}
