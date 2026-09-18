import Foundation

/// 桥接配置。令牌不进这里 —— 它在钥匙串。
struct RemoteBridgeConfig: Codable, Sendable {
    var enabled = false
    var host = ""
    var port = 8787
    /// 手机上允许用哪些能力。和电脑端 --allow 是**两道独立的闸**，
    /// 两道都开才通。手机这边是「我愿意用它」，电脑那边是「我允许你碰」。
    var capabilities: Set<String> = ["ask", "read", "ls"]

    var baseURL: URL? {
        guard !host.isBlank else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    static let allCapabilities = ["ask", "read", "ls", "exec", "write"]

    static func displayName(for capability: String) -> String {
        switch capability {
        case "ask": return "把任务交给电脑上的完整 DSH"
        case "read": return "读取电脑上的文件"
        case "ls": return "列出电脑上的目录"
        case "exec": return "在电脑上跑命令"
        case "write": return "往电脑上写文件"
        default: return capability
        }
    }

    static func isDangerous(_ capability: String) -> Bool {
        capability == "exec" || capability == "write"
    }
}

/// 桥接的持久化。令牌单独走钥匙串。
enum RemoteBridgeStore {
    private static let store = FileStore()
    private static let configPath = "bridge.json"
    private static let tokenKey = "dsh.bridge.token"

    static func load() -> RemoteBridgeConfig {
        store.load(RemoteBridgeConfig.self, from: configPath) ?? RemoteBridgeConfig()
    }

    static func save(_ config: RemoteBridgeConfig) {
        store.save(config, to: configPath)
    }

    static var token: String {
        get { Keychain.get(tokenKey) ?? "" }
        set { Keychain.set(newValue, for: tokenKey) }
    }
}

struct BridgeStatus: Sendable {
    var name: String
    var version: String
    var host: String
    var platform: String
    var capabilities: [String]
}

enum BridgeError: LocalizedError {
    case notConfigured
    case capabilityOff(String)
    case server(String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有连接电脑上的桥接"
        case .capabilityOff(let capability): return "「\(RemoteBridgeConfig.displayName(for: capability))」没有打开"
        case .server(let message): return message
        case .unreachable(let message): return "连不上电脑：\(message)"
        }
    }
}

/// 桥接客户端。
actor DSHBridgeClient {
    static let shared = DSHBridgeClient()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = 360
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func status() async throws -> BridgeStatus {
        let json = try await call("status", body: [:], ignoringCapability: true)
        guard json["ok"] as? Bool == true else {
            throw BridgeError.server(json["error"] as? String ?? "未知错误")
        }
        return BridgeStatus(
            name: json["name"] as? String ?? "桥接",
            version: json["version"] as? String ?? "?",
            host: json["host"] as? String ?? "?",
            platform: json["platform"] as? String ?? "?",
            capabilities: json["capabilities"] as? [String] ?? []
        )
    }

    func call(_ action: String, body: [String: Any], ignoringCapability: Bool = false) async throws -> [String: Any] {
        let config = RemoteBridgeStore.load()
        guard config.enabled, let base = config.baseURL else { throw BridgeError.notConfigured }
        guard ignoringCapability || config.capabilities.contains(action) else {
            throw BridgeError.capabilityOff(action)
        }
        let token = RemoteBridgeStore.token
        guard !token.isBlank else { throw BridgeError.notConfigured }

        var request = URLRequest(url: base.appendingPathComponent(action))
        request.httpMethod = action == "status" ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if request.httpMethod == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await session.aetherData(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                throw BridgeError.server("令牌不对，检查电脑那边打印的令牌")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BridgeError.server("桥接返回了看不懂的东西")
            }
            return json
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - 远程工具

/// 把电脑上的能力注册成手机上的工具。
///
/// 这就是方案 C 的全部：**不往 app 里塞任何东西**。
/// 桥接暴露什么，手机就多出什么工具；关掉桥接，这些工具自动失效。
enum RemoteBridgeTools {
    static func install(into registry: ToolRegistry = .builtin) {
        registry.register(AskRemoteTool())
        registry.register(RemoteExecTool())
        registry.register(RemoteReadTool())
        registry.register(RemoteWriteTool())
        registry.register(RemoteListTool())
    }
}

/// 把任务交给电脑上完整的 DSH。
///
/// 这是桥接里最值钱的一个：手机上的代理遇到搞不定的活，
/// 可以原样丢给电脑 —— 那边有全部工具、子代理和技能。
struct AskRemoteTool: AgentTool {
    let name = "dsh_ask"
    let summary = "把任务交给用户电脑上运行的完整 DSH 去做，返回它的结果。适合复杂、需要多步骤、或需要访问电脑文件的任务。"
    let parameters = [
        ToolParameter(name: "prompt", description: "要交给电脑的完整任务描述。它可以自己读文件、联网、开子代理，所以写得具体一点。"),
    ]
    let isReadOnly = false

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let prompt = arguments["prompt"], !prompt.isBlank else {
            return .fail("缺少 prompt")
        }
        do {
            let json = try await DSHBridgeClient.shared.call("ask", body: ["prompt": prompt])
            let output = (json["output"] as? String)?.trimmed ?? ""
            let ms = json["ms"] as? Int ?? 0
            if json["ok"] as? Bool == true, !output.isEmpty {
                return .ok(output, display: "电脑回来了（\(ms / 1000) 秒）")
            }
            return .fail(output.isEmpty ? "电脑没有返回内容" : output)
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

struct RemoteExecTool: AgentTool {
    let name = "dsh_exec"
    let summary = "在用户电脑上执行一条命令行指令。危险操作，默认关闭。"
    let parameters = [
        ToolParameter(name: "command", description: "要执行的命令"),
        ToolParameter(name: "cwd", description: "工作目录", required: false),
    ]
    let isReadOnly = false

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let command = arguments["command"], !command.isBlank else { return .fail("缺少 command") }
        do {
            var body: [String: Any] = ["command": command]
            if let cwd = arguments["cwd"], !cwd.isEmpty { body["cwd"] = cwd }
            let json = try await DSHBridgeClient.shared.call("exec", body: body)
            let stdout = (json["stdout"] as? String ?? "").trimmed
            let stderr = (json["stderr"] as? String ?? "").trimmed
            let code = json["code"] as? Int ?? -1
            let combined = [stdout, stderr.isEmpty ? nil : "stderr: " + stderr]
                .compactMap { $0 }.joined(separator: "\n")
            return json["ok"] as? Bool == true
                ? .ok(combined.isEmpty ? "（无输出）" : combined, display: "退出码 \(code)")
                : .fail(combined.isEmpty ? "退出码 \(code)" : combined)
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

struct RemoteReadTool: AgentTool {
    let name = "dsh_read"
    let summary = "读取用户电脑上的一个文本文件。"
    let parameters = [ToolParameter(name: "path", description: "文件的完整路径")]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let path = arguments["path"], !path.isBlank else { return .fail("缺少 path") }
        do {
            let json = try await DSHBridgeClient.shared.call("read", body: ["path": path])
            guard json["ok"] as? Bool == true else {
                return .fail(json["error"] as? String ?? "读不了")
            }
            let content = json["content"] as? String ?? ""
            return .ok(content, display: "读了 \(content.count) 字")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

struct RemoteWriteTool: AgentTool {
    let name = "dsh_write"
    let summary = "把内容写到用户电脑上的一个文件。危险操作，默认关闭。"
    let parameters = [
        ToolParameter(name: "path", description: "文件的完整路径"),
        ToolParameter(name: "content", description: "要写入的内容"),
    ]
    let isReadOnly = false

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        guard let path = arguments["path"], !path.isBlank else { return .fail("缺少 path") }
        do {
            let json = try await DSHBridgeClient.shared.call("write", body: [
                "path": path,
                "content": arguments["content"] ?? "",
            ])
            guard json["ok"] as? Bool == true else {
                return .fail(json["error"] as? String ?? "写不了")
            }
            return .ok("已写入 \(json["bytes"] as? Int ?? 0) 字节", display: "写好了")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

struct RemoteListTool: AgentTool {
    let name = "dsh_ls"
    let summary = "列出用户电脑上某个目录的内容。"
    let parameters = [ToolParameter(name: "path", description: "目录路径", required: false)]

    func run(_ arguments: [String: String], context: AgentContext) async -> ToolResult {
        do {
            var body: [String: Any] = [:]
            if let path = arguments["path"], !path.isEmpty { body["path"] = path }
            let json = try await DSHBridgeClient.shared.call("ls", body: body)
            guard json["ok"] as? Bool == true else {
                return .fail(json["error"] as? String ?? "列不了")
            }
            let entries = json["entries"] as? [[String: Any]] ?? []
            let lines = entries.map { entry in
                let name = entry["name"] as? String ?? "?"
                let isDir = entry["dir"] as? Bool ?? false
                return isDir ? "📁 \(name)/" : "   \(name)"
            }
            let where_ = json["path"] as? String ?? ""
            return .ok("\(where_)\n" + lines.joined(separator: "\n"), display: "\(entries.count) 项")
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
