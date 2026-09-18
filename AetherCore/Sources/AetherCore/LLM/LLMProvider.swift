import Foundation

struct LLMMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case system, user, assistant }
    var role: Role
    var content: String
    /// 图像：data URL 或 http URL，用于让角色「看图」
    var images: [String] = []
    /// 群聊里区分说话人
    var speaker: String?
}

struct LLMRequest: Sendable {
    var messages: [LLMMessage]
    var temperature: Double = 0.9
    var maxTokens: Int = 900
    var model: String = ""
    var stop: [String] = []
}

enum LLMError: LocalizedError {
    case missingAPIKey
    case badStatus(Int, String)
    case empty
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "还没有配置服务密钥"
        case .badStatus(let code, let body): return "服务返回 \(code)：\(body.prefix(160))"
        case .empty: return "服务没有返回内容"
        case .cancelled: return "已取消"
        }
    }
}

/// 文本生成 —— 流式。
protocol LLMProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

/// 画面比例。
///
/// 刻意不用 CGSize：CGSize 来自 CoreGraphics，用了它这个模块就没法在
/// Windows 上编译。各家图像接口要的本来也就是这几个档位。
enum ImageAspect: String, Sendable, CaseIterable {
    case square = "1024x1024"
    case portrait = "1024x1536"
    case landscape = "1536x1024"

    var width: Int {
        switch self {
        case .square: return 1024
        case .portrait: return 1024
        case .landscape: return 1536
        }
    }

    var height: Int {
        switch self {
        case .square: return 1024
        case .portrait: return 1536
        case .landscape: return 1024
        }
    }

    /// 按宽高比选档
    static func best(forWidth width: Double, height: Double) -> ImageAspect {
        let ratio = width / Swift.max(1, height)
        if ratio > 1.2 { return .landscape }
        if ratio < 0.83 { return .portrait }
        return .square
    }
}

/// 图像生成 —— 角色发「日常照片」靠它。
protocol ImageProvider: AnyObject, Sendable {
    func generate(prompt: String, aspect: ImageAspect) async throws -> Data
}

/// 向量化 —— 长期记忆检索靠它。
protocol EmbeddingProvider: AnyObject, Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}
