import Foundation

/// 代理运行过程中推给界面的事件。
enum AgentEvent: Sendable {
    case started(String)
    case thinking(String)
    case toolCall(name: String, arguments: [String: String])
    case toolResult(name: String, ok: Bool, summary: String)
    case answer(String)
    case failed(String)
    case finished(steps: Int)
}

/// 代理运行时 —— 「内置 DSH」的核心。
///
/// 它不是一条写死的流程，而是一个循环：
///   想 → 决定用哪个工具 → 执行 → 看结果 → 再想 → …… → 给答案
///
/// 工具调用沿用演出系统那套 ⟦⟧ 标记，理由一致：
/// 模型只需要产出文本，解析和权限全在客户端手里。
/// 格式：
///   ⟦think:先查一下她的设定⟧
///   ⟦tool:web_search⟧{"query":"钟离 原神 设定"}
/// 不想用工具时直接输出答案即可。
final class AgentRuntime: @unchecked Sendable {
    private let registry: ToolRegistry
    private let provider: LLMProvider
    private let maxSteps: Int
    private let temperature: Double

    init(
        registry: ToolRegistry = .builtin,
        provider: LLMProvider = ProviderHub.shared.llm,
        maxSteps: Int = 6,
        temperature: Double = 0.4
    ) {
        self.registry = registry
        self.provider = provider
        self.maxSteps = maxSteps
        self.temperature = temperature
    }

    var availableTools: [any AgentTool] { registry.all }

    func run(task: String, context: AgentContext) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let worker = Task { [self] in
                await execute(task: task, context: context, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    // MARK: - 主循环

    private func execute(
        task: String,
        context: AgentContext,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async {
        emit(.started(task))

        var messages: [LLMMessage] = [
            LLMMessage(role: .system, content: Self.systemPrompt(registry: registry, context: context)),
            LLMMessage(role: .user, content: task),
        ]
        var steps = 0

        while steps < maxSteps {
            if Task.isCancelled { emit(.finished(steps: steps)); return }
            steps += 1

            var raw = ""
            do {
                let request = LLMRequest(messages: messages, temperature: temperature, maxTokens: 900, model: "")
                for try await delta in provider.stream(request) { raw += delta }
            } catch {
                emit(.failed(error.localizedDescription))
                return
            }

            let parsed = Self.parse(raw)

            if let thought = parsed.thought, !thought.isBlank {
                emit(.thinking(thought))
            }

            guard let call = parsed.toolCall else {
                // 没有工具调用 —— 这就是最终答案
                let answer = CueParser.parse(raw).display.trimmed
                emit(.answer(answer.isEmpty ? raw.trimmed : answer))
                emit(.finished(steps: steps))
                return
            }

            emit(.toolCall(name: call.name, arguments: call.arguments))

            guard let tool = registry.tool(named: call.name) else {
                emit(.toolResult(name: call.name, ok: false, summary: "没有这个工具"))
                messages.append(LLMMessage(role: .assistant, content: raw))
                messages.append(LLMMessage(role: .user, content: "观察：工具 \(call.name) 不存在。可用工具见系统提示。"))
                continue
            }

            var scoped = context
            scoped.history.append(call.name)
            let result = await tool.run(call.arguments, context: scoped)
            emit(.toolResult(
                name: call.name,
                ok: result.ok,
                summary: result.display ?? String(result.content.prefix(120))
            ))

            // 把「我刚才说了什么」和「工具返回了什么」都塞回去，
            // 少一样模型都会开始重复调用同一个工具。
            messages.append(LLMMessage(role: .assistant, content: raw))
            messages.append(LLMMessage(role: .user, content: "观察：\n" + String(result.content.prefix(4000))))

            // 上下文快满了就丢最早的观察，保留任务与最近的
            if messages.count > 16 {
                let head = messages.prefix(2)
                let tail = messages.suffix(12)
                messages = Array(head) + Array(tail)
            }
        }

        emit(.answer("我已经用了 \(maxSteps) 步还没做完。要不要把任务拆小一点？"))
        emit(.finished(steps: steps))
    }

    // MARK: - 解析

    struct Parsed: Sendable {
        var thought: String?
        var toolCall: (name: String, arguments: [String: String])?
    }

    /// 从模型输出里抠出思考行与工具调用。
    static func parse(_ raw: String) -> Parsed {
        var parsed = Parsed()

        if let thoughtRange = firstMarker(in: raw, prefix: "think:") {
            parsed.thought = thoughtRange
        }

        guard let openRange = raw.range(of: "⟦tool:") else { return parsed }
        let afterOpen = raw[openRange.upperBound...]
        guard let closeIndex = afterOpen.firstIndex(of: "⟧") else { return parsed }

        let name = String(afterOpen[..<closeIndex]).trimmed
        guard !name.isEmpty else { return parsed }

        // 参数是同行的 JSON
        let rest = afterOpen[afterOpen.index(after: closeIndex)...]
        let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
        let jsonLine = String(rest[..<lineEnd]).trimmed

        parsed.toolCall = (name: name, arguments: parseArguments(jsonLine))
        return parsed
    }

    private static func firstMarker(in raw: String, prefix: String) -> String? {
        guard let open = raw.range(of: "⟦" + prefix) else { return nil }
        let rest = raw[open.upperBound...]
        guard let close = rest.firstIndex(of: "⟧") else { return nil }
        return String(rest[..<close]).trimmed
    }

    /// 参数既接受 JSON，也接受 key=value 的松散写法 —— 模型两种都会写。
    static func parseArguments(_ text: String) -> [String: String] {
        guard !text.isEmpty else { return [:] }

        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result: [String: String] = [:]
            for (key, value) in dict {
                if let string = value as? String { result[key] = string }
                else if let number = value as? NSNumber { result[key] = number.stringValue }
                else if let array = value as? [String] { result[key] = array.joined(separator: ",") }
            }
            return result
        }

        var result: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    // MARK: - 提示词

    static func systemPrompt(registry: ToolRegistry, context: AgentContext) -> String {
        """
        你是一个代理（agent）。你的工作是**动手把事情做完**，不是解释怎么做。

        ## 你有哪些工具
        \(registry.briefing)

        ## 怎么用
        想要调用工具，就单独起一行，写成：
        ⟦tool:工具名⟧{"参数名":"参数值"}

        想说明自己在打算干什么，另起一行写：
        ⟦think:一句话说明⟧

        拿定主意要收尾时，**不要**再写工具调用，直接输出给用户的答案。

        ## 纪律
        1. 一次只调一个工具，看完结果再决定下一步。
        2. 同样的参数不要调两次。工具报错就换个思路，别重试。
        3. 手里已经有足够信息时就收尾，不要为了「更完整」再多查一轮。
        4. 找不到就直说找不到。**不要编造**查不到的事实。
        5. 最终答案是给用户看的中文，说人话，别复述工具输出。

        ## 当前场景
        发起人：\(context.actor)
        \(context.personaID != nil ? "关联角色已指定" : "没有指定关联角色")
        \(context.history.isEmpty ? "" : "已经用过：" + context.history.joined(separator: "、"))
        """
    }
}
