# 没有 Mac，怎么验证这份工程

你手上只有 Windows。现状是：**iOS 界面本身在 Windows 上无解**（SwiftUI / RealityKit
的编译器就不存在），但**工程能不能编译、逻辑对不对，这两件事完全可以验证**。

所以工程在结构上做了拆分。

## 拆分：内核 vs 外壳

```
AetherChat/
├── AetherCore/                 ← SwiftPM 包，纯 Foundation，跨平台
│   ├── Package.swift
│   ├── Sources/AetherCore/
│   │   ├── Models/             九个纯值类型
│   │   ├── Persistence/        FileStore + WorldStore
│   │   ├── LLM/                provider 协议 / 演出指令解析 / 沉浸守门 / 离线引擎
│   │   ├── Memory/             上下文引擎 / 向量 / 记忆抽取 / 摘要
│   │   ├── Orchestration/      单聊编排 / 群聊导演 / 关系引擎
│   │   ├── Canon/              资料抓取 / 复刻研究员 / 人格铸造厂
│   │   └── Support/            SHA-256 / 日志垫片 / 钥匙串垫片 / 扩展
│   └── Tests/AetherCoreTests/  五个测试套件
│
├── AetherKit/                  ← 苹果专属（依赖 AetherCore）
│   ├── Avatar/  Effects/  Voice/  Media/  Support/Vault.swift
│   └── Orchestration/AutonomyScheduler.swift
├── Features/                   ← 界面
└── App/                        ← 装配
```

判据很简单：**这个文件 import 了 SwiftUI / UIKit / AVFoundation / Security / OSLog 吗？**
是 → 留在外壳。否 → 进内核。

内核里现在一行苹果专属依赖都没有（`Log` 和 `Keychain` 例外，
它们用 `#if canImport(...)` 做了跨平台分支，非苹果平台退化成控制台输出和内存字典）。

## 路径 C：在 Windows 上跑内核测试

### 1. 装 Swift 工具链

```powershell
winget install Swift.Toolchain
```

或者从 <https://www.swift.org/install/windows/> 下安装包。
装完开一个新的终端，验证：

```powershell
swift --version
```

需要 Swift 5.9 或更高（工程按 5.10 写的，5.9 也能编）。

### 2. 跑测试

```powershell
cd F:\DeepSeek-Harness\workspace\AetherChat
swift test --package-path AetherCore
```

第一次会编译一两分钟，之后是秒级。看到类似这样就是全绿了：

```
Test Suite 'All tests' passed
Executed 34 tests, with 0 failures
```

### 3. 你会得到什么

这些测试是真的在跑，不是占位：

| 测试套件 | 验证的是 |
|---|---|
| `CueParserTests` | 演出指令的流式解析。**包括「标记被网络分片切断时不能漏到屏幕上」**——这是最容易出、也最难发现的一类 bug |
| `SHA256Tests` | 自实现的 SHA-256 对得上公开测试向量（人格指纹与向量桶位的地基） |
| `PersonaFidelityTests` | 人格冻结、指纹校验、换皮不换人、偷改内核必然被抓、重铸留痕 |
| `ContextEngineTests` | 人格每轮重锚、相关记忆赢过噪音、摘要游标不重复注入、中文 token 估算 |
| `RelationshipAndGroupTests` | 关系随话语演化、时间衰减、被点名者优先接话、刚说过话的人让位 |
| `EndToEndOfflineTests` | 一整轮对话跑通：落库、关系变化、隐藏轨迹回填、演出标记不泄漏、沉浸守门擦除、离线记忆抽取 |

### 4. 它测不到什么

说清楚边界，免得误判：

- **界面**。SwiftUI 视图、动画、手势，全都不在内核里，测不到。
- **形象渲染**。Live2D / RealityKit / 立绘，都在外壳。
- **语音与通话**。AVFoundation 相关，在外壳。
- **真实模型的输出质量**。MockProvider 只保证管线通，不保证台词好。
- **真实的资料抓取**。`ResearchAgent` 的网络路径要真联网才走得到（结构上没被排除，
  但测试里没有覆盖）。

也就是说：**内核的骨架是硬的，但「她看起来活不活」仍然需要一台 Mac 才能确认。**

## 路径 A：云上编译整个 app

内核过了之后，界面那部分要靠 GitHub Actions 的 macOS runner。

```bash
cd F:/DeepSeek-Harness/workspace/AetherChat
git init && git add -A && git commit -m "feat: AetherChat 初版"
gh repo create aether-chat --public --source=. --push
```

（没有 `gh` 就手动在 GitHub 建库再 `git remote add origin ... && git push`。）

推上去之后两个 workflow 会同时跑：

- **Core Tests** —— ubuntu / macOS / Windows 三平台跑内核测试（Windows 暂时不挡路）
- **iOS Build** —— macOS runner 上 `xcodegen generate` + `xcodebuild build`，
  编译整包，报错日志存成 artifact

跑完去 Actions 页面下载 `build-log`，把报错贴回来，我改，再推，十几分钟一轮。

**公开仓库的 macOS runner 是免费的，也不限时长。** 这个工程里没有任何密钥
（API Key 存在用户设备的钥匙串里，不进代码），公开没有风险。

## 三条路径的分工

| | 能验证什么 | 需要什么 | 成本 |
|---|---|---|---|
| **C 内核测试** | 逻辑正确性 | Windows + Swift 工具链 | 免费 |
| **A 云编译** | 整个 app 能否编译 | 一个 GitHub 仓库 | 免费（公开库） |
| **B 租云 Mac** | 界面到底长什么样、演出效果好不好看 | 按小时租的 macOS 机器 | 按小时计费 |

A 和 C 能让你把「这份代码是不是一堆看着合理的废纸」这件事彻底确认掉，
但它们**都不会给你一张界面截图**。要看到她在屏幕上呼吸、下雨、脸红，只有 B。
