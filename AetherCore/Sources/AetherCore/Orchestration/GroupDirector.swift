import Foundation

/// 群聊导演。
///
/// 难点不是「让 AI 说话」，是**谁来说**。
/// 如果按顺序轮流发言，群聊立刻变成播报；如果谁都说，立刻变成菜市场。
/// 这里的做法是给每个人打一个「此刻想不想说话」的分，然后按分排序取前几名。
final class GroupDirector: @unchecked Sendable {
    struct Turn: Sendable {
        var personaID: UUID
        var score: Double
        var reason: String
    }

    private let store: WorldStore

    init(store: WorldStore = .shared) {
        self.store = store
    }

    /// 决定这一轮谁来接话。
    func planTurns(
        conversation: Conversation,
        personas: [Persona],
        edges: [RelationshipEdge],
        lastUserText: String,
        recentSpeakerIDs: [UUID],
        maxTurns: Int = 3
    ) -> [Turn] {
        var turns: [Turn] = []
        let text = lastUserText.lowercased()

        for persona in personas {
            guard let participant = conversation.participant(persona.id) else { continue }
            var score = 0.0
            var reasons: [String] = []

            // 被点名 —— 最强信号
            if text.contains(persona.name.lowercased()) {
                score += 0.65
                reasons.append("被点名")
            }

            // 话题契合：她关心的事正好被聊到
            let interests = persona.core.seed.interests.map { $0.lowercased() }
            let hits = interests.filter { !$0.isEmpty && text.contains($0) }
            if !hits.isEmpty {
                score += min(0.35, Double(hits.count) * 0.18)
                reasons.append("话题命中(\(hits.joined(separator: "/")))")
            }

            // 性格活跃度
            score += participant.chattiness * 0.30
            if participant.chattiness > 0.7 { reasons.append("话多") }

            // 关系张力：憋着话的人更容易开口
            let edge = edges.first { $0.fromID == persona.id && $0.toID == nil }
            if let edge {
                if edge.tension > 0.5 {
                    score += 0.22
                    reasons.append("有情绪")
                }
                if edge.affinity > 0.6 { score += 0.12 }

                // 别人刚说过她 —— 她会反驳
                for speakerID in recentSpeakerIDs {
                    if let speaker = personas.first(where: { $0.id == speakerID }),
                       text.contains(speaker.name.lowercased()) {
                        score += 0.10
                    }
                }
            }

            // 刚说过话的人让一让
            if let lastIndex = recentSpeakerIDs.lastIndex(of: persona.id) {
                let distance = recentSpeakerIDs.count - lastIndex
                score -= distance <= 1 ? 0.45 : 0.15
                reasons.append("刚说过")
            }

            // 一点随机，避免每次都同一个人先开口
            score += Double.random(in: -0.08...0.08)
            turns.append(Turn(personaID: persona.id, score: score, reason: reasons.joined(separator: "、")))
        }

        return turns
            .sorted { $0.score > $1.score }
            .prefix(maxTurns)
            .filter { $0.score > 0.18 }
            .map { $0 }
    }

    /// 生成本轮群聊的全部发言，逐条推给界面。
    func run(
        conversationID: UUID,
        userText: String
    ) -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.execute(conversationID: conversationID, userText: userText) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        conversationID: UUID,
        userText: String,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async {
        let settings = await store.currentSettings()
        guard let conversation = await store.conversation(conversationID) else { return }
        let allPersonas = await store.personas(conversation.personaIDs)
        guard !allPersonas.isEmpty else { return }
        let history = await store.messages(in: conversationID, limit: 60)

        // 用户在群里发的消息先落库
        var userMessage = Message(
            conversationID: conversationID, authorID: nil, role: .user,
            kind: .text, text: userText
        )
        userMessage.state = .delivered
        await store.append(userMessage)
        emit(.userMessage(userMessage))

        var recentSpeakers: [UUID] = history.suffix(6).compactMap { $0.authorID }
        var perPersonaHistory: [UUID: [Message]] = [:]
        for persona in allPersonas { perPersonaHistory[persona.id] = history }

        // 一轮最多 3 个回合；一个回合结束后，重新打分（因为现场变了）
        for round in 0..<3 {
            let edges = await store.allEdges()
            let turns = planTurns(
                conversation: conversation,
                personas: allPersonas,
                edges: edges,
                lastUserText: userText,
                recentSpeakerIDs: recentSpeakers,
                maxTurns: 1
            )
            guard let turn = turns.first,
                  let speaker = allPersonas.first(where: { $0.id == turn.personaID }) else { break }

            Log.autonomy.debug("group turn \(round): \(speaker.name) score=\(turn.score) (\(turn.reason))")

            let others = allPersonas.filter { $0.id != speaker.id }
            let engine = ContextEngine(embedder: ProviderHub.shared.embedder)
            let memories = await store.memories(stream: speaker.memoryStreamID)
            let canon = await store.bundlesFor(speaker.id)
            let edge = await store.edge(from: speaker.id, to: nil)

            let workingSet = await engine.workingSet(
                persona: speaker,
                conversation: conversation,
                history: perPersonaHistory[speaker.id] ?? [],
                memories: memories,
                canon: canon,
                edge: edge,
                settings: settings,
                userInput: userText,
                extraParticipants: others
            )

            let phrase = ImmersionGuard.typingPhrase(seed: round &* 7 &+ speaker.name.count, tempo: speaker.presentation.typingTempo)
            emit(.typingStarted(personaID: speaker.id, phrase: phrase))

            var parser = CueStreamParser()
            var buffer = ""
            var cues: [PerformanceCue] = []
            var emotion: EmotionState?
            var monologue: String?

            let request = LLMRequest(
                messages: workingSet.messages,
                temperature: settings.temperature,
                maxTokens: min(settings.maxTokens, 400),
                model: settings.chatModel
            )

            do {
                for try await delta in ProviderHub.shared.llm.stream(request) {
                    let out = parser.feed(delta)
                    if !out.display.isEmpty {
                        buffer += out.display
                        emit(.partial(text: buffer, emotion: out.emotion ?? emotion))
                    }
                    if let emo = out.emotion {
                        emotion = emo
                        emit(.emotionChanged(personaID: speaker.id, emotion: emo))
                    }
                    if let inner = out.monologue { monologue = inner }
                    for cue in out.cues where cue.channel != .pacing {
                        cues.append(cue)
                        emit(.actions(personaID: speaker.id, cues: [cue]))
                    }
                }
            } catch {
                emit(.failed(error.localizedDescription))
                return
            }

            let tail = parser.finish()
            buffer += tail.display

            let (clean, blocked) = settings.immersionGuardEnabled
                ? ImmersionGuard.scrub(buffer)
                : (buffer, 0)
            guard !clean.trimmed.isEmpty else { continue }

            var message = Message(
                conversationID: conversationID,
                authorID: speaker.id,
                role: .persona,
                kind: .text,
                text: clean.trimmed
            )
            message.cues = cues
            message.emotion = emotion
            message.hidden.recalledMemoryIDs = workingSet.recalledMemories.map { $0.id }
            message.hidden.canonFactIDs = workingSet.usedCanonFacts.map { $0.id }
            message.hidden.promptTokens = workingSet.tokenEstimate
            message.hidden.oocBlocks = blocked
            message.hidden.notes = ["群聊回合 \(round + 1)：\(turn.reason)"]
            if let monologue { message.hidden.innerMonologue = monologue }

            await store.append(message)
            emit(.segment(message))
            emit(.finished(personaID: speaker.id))
            if let last = message.hidden.innerMonologue, settings.keepInnerMonologue {
                Log.stage.debug("inner: \(last.prefix(40))")
            }

            // 群聊会改变他们彼此的关系
            let interEdges = RelationshipEngine().updateInterCharacterEdges(
                speaker: speaker.id,
                audience: others.map { $0.id },
                speakerText: clean,
                speakerEmotion: emotion
            )
            await store.upsertEdges(interEdges)

            recentSpeakers.append(speaker.id)
            for persona in allPersonas {
                var list = perPersonaHistory[persona.id] ?? []
                list.append(message)
                perPersonaHistory[persona.id] = list
            }
            // 让下一位看到「刚才谁说了什么」
            if round < 2 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
    }
}
