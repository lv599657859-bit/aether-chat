import Foundation

/// 一次工具调用的结果。
struct ToolResult: Sendable {
    var ok: Bool
    /// 回给模型看的文本
    var content: String
    /// 给人看的一句话（代理控制台里显示）
    var display: String?
    /// 产生的资源引用（文件名、UUID 等）
    var artifacts: [String] = []

    static func ok(_ content: String, display: String? = nil, artifacts: [String] = []) -> ToolResult {
        ToolResult(ok: true, content: content, display: display, artifacts: artifacts)
    }

    static func fail(_ reason: String) -> ToolResult {
        ToolResult(ok: false, content: "失败：\(reason)", display: reason)
    }
}

struct ToolParameter: Sendable {
    var name: String
    var description: String
    var required: Bool = true
}

/// 调用工具时携带的上下文。
struct AgentContext: Sendable {
    var personaID: UUID?
    var conversationID: UUID?
    /// 谁在下命令，用于日志和权限判断
    var actor: String = "用户"
    /// 前几轮已经用过什么，避免死循环
    var history: [String] = []
}

/// 工具。
///
/// 这是「能力以注册的方式接进来，而不是写死在流程里」的落点 ——
/// AstrBot 的插件注册表就是这个想法：加一个能力 = 注册一个类，
/// 不改流水线、不改 prompt 模板。
protocol AgentTool: Sendable {
    var name: String { get }
    var summary: String { get }
    var parameters: [ToolParameter] { get }
    /// 只读工具可以并行；有副作用的工具会串行执行
    var isReadOnly: Bool { get }
    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult
}

extension AgentTool {
    var isReadOnly: Bool { true }

    /// 给模型看的单条说明
    var briefing: String {
        let args = parameters.map { parameter in
            parameter.required ? "\(parameter.name)" : "[\(parameter.name)]"
        }.joined(separator: ", ")
        return "- \(name)(\(args))：\(summary)"
    }

    /// 给模型看的参数细则
    var detail: String {
        parameters.map { "    \($0.name)：\($0.description)" }.joined(separator: "\n")
    }
}

/// 工具注册表。
final class ToolRegistry: @unchecked Sendable {
    static let shared = ToolRegistry()
    static let builtin: ToolRegistry = {
        let registry = ToolRegistry()
        BuiltinTools.install(into: registry)
        return registry
    }()

    private var tools: [String: any AgentTool] = [:]
    private let lock = NSLock()

    init() {}

    func register(_ tool: any AgentTool) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.name] = tool
    }

    func tool(named name: String) -> (any AgentTool)? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    var all: [any AgentTool] {
        lock.lock(); defer { lock.unlock() }
        return tools.values.sorted { $0.name < $1.name }
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return tools.isEmpty
    }

    /// 拼进 system prompt 的工具清单。
    var briefing: String {
        let list = all
        guard !list.isEmpty else { return "（当前没有可用工具）" }
        return list.map { "\($0.briefing)\n\($0.detail)" }.joined(separator: "\n")
    }
}
