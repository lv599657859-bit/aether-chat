import Foundation

#if canImport(OSLog)
import OSLog

/// 苹果平台的日志：走 OSLog，可在 Console.app 里按 category 过滤。
/// 只进控制台，**不进聊天界面** —— 沉浸感第一。
enum Log {
    static let subsystem = "com.aether.chat"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let llm = Logger(subsystem: subsystem, category: "llm")
    static let memory = Logger(subsystem: subsystem, category: "memory")
    static let canon = Logger(subsystem: subsystem, category: "canon")
    static let stage = Logger(subsystem: subsystem, category: "stage")
    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let autonomy = Logger(subsystem: subsystem, category: "autonomy")
}

#else

/// 非苹果平台（Windows / Linux）的降级：直接打到 stdout。
///
/// 存在的唯一理由：让内核能在没有 Mac 的机器上编译并跑测试。
/// 接口和上面的 Logger 完全一致（debug / info / error 都收 String），
/// 所以调用点一行都不用改。
struct ConsoleLogger: Sendable {
    let category: String

    func debug(_ message: String) { print("[\(category)] DEBUG \(message)") }
    func info(_ message: String) { print("[\(category)] INFO  \(message)") }
    func error(_ message: String) { print("[\(category)] ERROR \(message)") }
    func warning(_ message: String) { print("[\(category)] WARN  \(message)") }
}

enum Log {
    static let subsystem = "com.aether.chat"
    static let app = ConsoleLogger(category: "app")
    static let llm = ConsoleLogger(category: "llm")
    static let memory = ConsoleLogger(category: "memory")
    static let canon = ConsoleLogger(category: "canon")
    static let stage = ConsoleLogger(category: "stage")
    static let voice = ConsoleLogger(category: "voice")
    static let autonomy = ConsoleLogger(category: "autonomy")
}

#endif
