import Foundation

/// 借用电脑上的模型。
///
/// 存在的理由：手机上不配任何密钥，也能用上完整的模型能力。
/// 做法是把 system + 对话原样发给桥接的 /complete，让电脑那边的
/// DSH 去跑，文本原样回来。
///
/// 代价说清楚：**它不是流式的**。电脑把整段答完才回，所以聊天里
/// 看不到逐字浮现的打字效果，是一次性出现一整条。
/// 复刻、记忆抽取、摘要这些「慢一点无所谓、质量更重要」的地方
/// 最适合它；聊天用它就少了点味道。
final class RemoteLLMProvider: LLMProvider, @unchecked Sendable {
    let id = "remote"
    let displayName = "电脑上的模型"

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let system = request.messages.first { $0.role == .system }?.content ?? ""
                    let conversation = request.messages
                        .filter { $0.role != .system }
                        .map { message -> String in
                            switch message.role {
                            case .user: return "用户：" + message.content
                            case .assistant: return "助手：" + message.content
                            case .system: return message.content
                            }
                        }
                        .joined(separator: "\n\n")

                    let json = try await DSHBridgeClient.shared.call("complete", body: [
                        "system": system,
                        "prompt": conversation,
                    ])
                    guard json["ok"] as? Bool == true else {
                        throw LLMError.badStatus(-1, json["error"] as? String ?? "电脑没有返回内容")
                    }
                    continuation.yield(json["output"] as? String ?? "")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
