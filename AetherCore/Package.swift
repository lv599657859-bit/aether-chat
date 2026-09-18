// swift-tools-version: 5.9
import PackageDescription

/// AetherCore —— 跨平台内核。
///
/// 这里只放纯 Foundation 的代码：模型、上下文引擎、演出指令解析、关系与编排、
/// 复刻管线、本地存储。**没有 SwiftUI、没有 UIKit、没有 AVFoundation、没有 CryptoKit。**
///
/// 这样做的直接好处：它在 Windows 和 Linux 上都能编译，能在你的 PC 上跑单元测试。
/// 苹果专属的部分（形象渲染、语音、通话、界面）留在 App 目标里，依赖这个包。
let package = Package(
    name: "AetherCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "AetherCore", targets: ["AetherCore"])
    ],
    targets: [
        .target(
            name: "AetherCore",
            path: "Sources/AetherCore"
        ),
        .testTarget(
            name: "AetherCoreTests",
            dependencies: ["AetherCore"],
            path: "Tests/AetherCoreTests"
        )
    ]
)
