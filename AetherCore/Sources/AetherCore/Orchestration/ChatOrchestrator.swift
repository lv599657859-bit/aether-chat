import Foundation

/// 聊天过程中从引擎流向界面的东西。
/// 注意：这里**没有** token、没有"思考中"、没有模型名 —— 那些全在 Message.hidden 里。
enum ChatEvent: Sendable {
    case userMessage(Message)
    case typingStarted(personaID: UUID, phrase: String)
    case partial(text: String, emotion: EmotionState?)
    /// 一段话说完（可能是一整条，也可能是 pacing.split 切出来的一条）
    case segment(Message)
    case actions(personaID: UUID, cues: [PerformanceCue])
    case emotionChanged(personaID: UUID, emotion: EmotionState)
    case finished(personaID: UUID)
    case failed(String)
}

/// 单聊编排器 —— 一轮对话的完整流水线。
///
/// 一次 send() 背后发生的事（用户全都看不见）：
///   1. 落库用户消息
///   2. 更新关系数值
///   3. 组装上下文（人格 + canon + 长期记忆 + 摘要 + 原文窗口 + 演出协议）
///   4. 流式生成
///   5. 实时解析演出指令，边生成边驱动舞台
///   6. 按 pacing 指令把一段话拆成多条气泡（真人感）
///   7. 沉浸守门擦除越界输出
///   8. 落库 + 回填隐藏轨迹
///   9. 后台抽取记忆、必要时压缩上下文、推进角色之间的关系
final class ChatOrchestrator: @unchecked Sendable {
    private let store: WorldStore
    private let relationships = RelationshipEngine()
    private let budget: ContextBudget

    init(store: WorldStore = .shared, budget: ContextBudget = .standard) {
        self.store = store
        self.budget = budget
    }

    func send(
        text: String,
        attachments: [Attachment] = [],
        in conversationID: UUID,
        replyTo: UUID? = nil
    ) -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(
                    text: text,
                    attachments: attachments,
                    conversationID: conversationID,
                    replyTo: replyTo,
                    emit: { continuation.yield($0) }
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 主流程

    private func run(
        text: String,
        attachments: [Attachment],
        conversationID: UUID,
        replyTo: UUID?,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async {
        let settings = await store.currentSettings()
        guard let conversation = await store.conversation(conversationID) else { return }
        guard let personaID = conversation.personaIDs.first,
              let persona = await store.persona(personaID) else { return }

        // 1. 落库用户消息
        let kind: MessageKind = attachments.isEmpty ? .text
            : (attachments.first?.kind == .audio ? .voiceNote : .image)
        var userMessage = Message(
            conversationID: conversationID,
            authorID: nil,
            role: .user,
            kind: kind,
            text: text,
            attachments: attachments,
            replyToID: replyTo
        )
        userMessage.state = .delivered
        await store.append(userMessage)
        emit(.userMessage(userMessage))

        // 2. 流水线 —— 消息不是「进来就回」
        //    限流 → 兴趣度 → 心流 → 沉浸守门。任何一环都能拦下这次回复。
        var pipelineContext = ReplyContext(
            conversationID: conversationID,
            persona: persona,
            incomingText: text,
            attachments: attachments,
            isGroup: conversation.isGroup,
            store: store
        )
        pipelineContext = await ReplyPipeline.standard.run(pipelineContext)
        await MindFlow.shared.noteIncoming(persona.id)

        guard pipelineContext.shouldReply else {
            Log.autonomy.debug("pipeline suppressed: \(pipelineContext.suppressReason ?? "-")")
            emit(.finished(personaID: personaID))
            return
        }
        if pipelineContext.replyDelay > 0 {
            let capped = min(pipelineContext.replyDelay, 25)
            emit(.typingStarted(personaID: personaID, phrase: "……"))
            try? await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000))
        }

        // 3. 关系推进
        var edge = await store.edge(from: personaID, to: nil)
        edge = relationships.updateUserEdge(edge, userText: text, personaReplied: true)
        await store.upsert(edge)

        // 4. 组装上下文
        let engine = ContextEngine(embedder: ProviderHub.shared.embedder, budget: budget)
        let history = await store.messages(in: conversationID)
        let memories = await store.memories(stream: persona.memoryStreamID)
        let canon = await store.bundlesFor(personaID)
        let workingSet = await engine.workingSet(
            persona: persona,
            conversation: conversation,
            history: history,
            memories: memories,
            canon: canon,
            edge: edge,
            settings: settings,
            userInput: text
        )

        // 流水线各环节追加的说明，拼进 system prompt
        if !pipelineContext.injections.isEmpty {
            let merged = workingSet.systemPrompt + "\n\n" + pipelineContext.injections.joined(separator: "\n\n")
            workingSet.systemPrompt = merged
            if !workingSet.messages.isEmpty {
                workingSet.messages[0] = LLMMessage(role: .system, content: merged)
            }
            workingSet.notes.append("流水线注入 \(pipelineContext.injections.count) 条")
        }

        // 5. 打字中……（用角色化的文案，不用「正在生成」）
        let phrase = ImmersionGuard.typingPhrase(
            seed: text.count + Int(Date().timeIntervalSince1970),
            tempo: persona.presentation.typingTempo
        )
        emit(.typingStarted(personaID: personaID, phrase: phrase))

        // 6. 流式生成 + 实时解析演出
        let started = Date()
        var parser = CueStreamParser()
        var currentSegment = ""
        var segments: [Message] = []
        var pendingCues: [PerformanceCue] = []
        var emotion: EmotionState?
        var monologue: String?
        var blocks = 0
        var noteBuffer = ""

        func flushSegment(final: Bool) {
            let clean = currentSegment.trimmed
            guard !clean.isEmpty || final else { return }
            let (scrubbed, blocked) = settings.immersionGuardEnabled
                ? ImmersionGuard.scrub(currentSegment)
                : (currentSegment, 0)
            blocks += blocked
            var message = Message(
                conversationID: conversationID,
                authorID: personaID,
                role: .persona,
                kind: .text,
                text: scrubbed.trimmed
            )
            message.cues = pendingCues
            message.emotion = emotion
            message.hidden.recalledMemoryIDs = workingSet.recalledMemories.map { $0.id }
            message.hidden.canonFactIDs = workingSet.usedCanonFacts.map { $0.id }
            message.hidden.providerID = ProviderHub.shared.llm.id
            message.hidden.modelID = settings.chatModel
            message.hidden.promptTokens = workingSet.tokenEstimate
            message.hidden.notes = workingSet.notes + pipelineContext.trace
            message.hidden.oocBlocks = blocks
            if let monologue { message.hidden.innerMonologue = monologue }
            segments.append(message)
            currentSegment = ""
            pendingCues = []
            noteBuffer = ""
        }

        let request = LLMRequest(
            messages: workingSet.messages,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            model: settings.chatModel
        )

        do {
            for try await delta in ProviderHub.shared.llm.stream(request) {
                let out = parser.feed(delta)
                if !out.display.isEmpty {
                    currentSegment += out.display
                    noteBuffer += out.display
                    emit(.partial(text: currentSegment, emotion: out.emotion ?? emotion))
                }
                if let emo = out.emotion {
                    emotion = emo
                    emit(.emotionChanged(personaID: personaID, emotion: emo))
                }
                if let inner = out.monologue {
                    monologue = inner
                    if settings.keepInnerMonologue {
                        noteBuffer = ""
                    }
                }
                for cue in out.cues {
                    // 节拍指令：把前面那段话作为独立气泡发出去，模拟真人连发
                    if cue.channel == .pacing {
                        flushSegment(final: false)
                        continue
                    }
                    pendingCues.append(cue)
                    emit(.actions(personaID: personaID, cues: [cue]))
                    // 打字机 / 停顿：让节拍真的体现在时间上
                    if cue.delay > 0 {
                        let scaled = cue.delay * (0.4 + persona.presentation.typingTempo)
                        try? await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
                    }
                }
            }
        } catch {
            emit(.failed(error.localizedDescription))
            return
        }

        let tail = parser.finish()
        if !tail.display.isEmpty { currentSegment += tail.display }
        flushSegment(final: true)

        var delivered = segments
        if delivered.isEmpty {
            var fallback = Message(
                conversationID: conversationID, authorID: personaID,
                role: .persona, kind: .text, text: "……"
            )
            fallback.hidden.notes = ["空回复兜底"]
            delivered = [fallback]
        }
        for i in delivered.indices {
            delivered[i].hidden.durationMS = Int(Date().timeIntervalSince(started) * 1000)
        }

        await store.append(contentsOf: delivered, to: conversationID)

        // 心流：这一轮说上话了，把她的状态更新掉
        await MindFlow.shared.noteSpoken(personaID)
        if let emotion = delivered.compactMap({ $0.emotion }).last {
            await MindFlow.shared.setMood(personaID, mood: emotion)
        }
        for message in delivered { emit(.segment(message)) }
        emit(.finished(personaID: personaID))

        // 后台：记忆、摘要、关系
        await postProcess(
            persona: persona,
            conversation: conversation,
            userText: text,
            replyText: delivered.map { $0.text }.joined(separator: " "),
            lastMessageID: delivered.last?.id,
            settings: settings
        )
    }

    // MARK: - 后台维护

    private func postProcess(
        persona: Persona,
        conversation: Conversation,
        userText: String,
        replyText: String,
        lastMessageID: UUID?,
        settings: AppSettings
    ) async {
        // 记忆抽取
        let extractor = MemoryExtractor(provider: ProviderHub.shared.llm, embedder: ProviderHub.shared.embedder)
        let items = await extractor.extract(
            userText: userText,
            personaText: replyText,
            streamID: persona.memoryStreamID,
            sourceMessageID: lastMessageID
        )
        if !items.isEmpty {
            await store.upsertMemories(items)
        }

        // 上下文压缩（用户要求：自动解决，但不显示）
        guard settings.contextEngineEnabled else { return }
        let history = await store.messages(in: conversation.id)
        let totalChars = history.reduce(0) { $0 + $1.text.count }
        guard totalChars > settings.autoSummarizeThreshold else { return }

        let summarizer = Summarizer(provider: ProviderHub.shared.llm)
        guard let current = await store.conversation(conversation.id) else { return }
        if let result = await summarizer.summarize(
            conversation: current, history: history, personaName: persona.name
        ) {
            await store.setDigest(result.digest, for: conversation.id)
        }
    }

    /// 冷启动维护：关系随时间变淡、记忆随时间褪色。
    func performMaintenance() async {
        let edges = await store.allEdges()
        await store.upsertEdges(relationships.tick(edges: edges))
        await store.decayMemories()
    }
}
