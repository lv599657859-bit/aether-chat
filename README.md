# 灵犀 · AetherChat

一个 iOS 上的 AI 角色聊天应用。你要的不是「聊天机器人」，是**一些人住在手机里**。

所以这个工程的重心不在"接个大模型"，而在四件事：

1. **她能演** —— 文字、表情、动作、屏幕特效、环境音、震动，全部由一套演出协议驱动
2. **她记得** —— 上下文引擎在后台滚动压缩、向量检索、随时间遗忘，用户全程看不见
3. **她是她** —— 人格一次浇筑、永久固化，之后能改的只有皮，不是人
4. **他们会自己活** —— 角色会主动找你，也会在你不知道的时候彼此发展关系

---

## 你的需求 → 落点在哪

| 你要的 | 在哪实现 | 说明 |
|---|---|---|
| 2D / 3D 形象 | `AetherKit/Avatar/` | 四种运行时：Live2D（桥接）、RealityKit 3D、分层立绘、光核。缺素材自动逐级降级，绝不白屏 |
| 很多演出效果 | `AetherKit/Effects/` + `Features/Stage/` | 模型只输出「感觉」，导演决定「怎么演」。雨/雪/樱花/萤火/闪光/故障/暗角全部 Canvas 现画，零素材 |
| 发图片、发日常 | `AetherKit/Media/ImageStudio.swift` | 三层锁脸（canon 外貌锚点 + 参考图 + 固定机位模板），保证每张照片是同一个人 |
| 接打电话 | `AetherKit/Voice/CallSession.swift` | 完整状态机 + **打断（barge-in）**：她说到一半你开口，她会停下来听 |
| 发语音 | `VoiceNoteRecorder.swift` + `Transcriber.swift` | 录音 + 实时波形 + 转写；播放时角色嘴会跟着动 |
| 自己解决上下文，但不显示 | `AetherCore/Memory/ContextEngine.swift` | 滚动摘要 + 向量检索 + 按话题注入 canon + 关系数值转语气。痕迹全进 `Message.hidden`，只在潜意识层可读 |
| 隐私设置藏在暗处 | `Features/Vault/` + `Support/Vault.swift` | 没有入口按钮。连点聊天标题 5 次（或长按设置页版本号 3 秒）+ 面容 ID |
| 一代人格不再更改 | `AetherCore/Models/Persona.swift` | `PersonaCore` 冻结即只读，指纹校验；表现层可随便改。改内核必须走「重铸」并留下印章 |
| 新建很多 AI 联系人 | `Features/Persona/PersonaStudioView.swift` | 原创手搓 / 作品复刻两条路 |
| 建群聊 | `AetherCore/Orchestration/GroupDirector.swift` | 不是轮流发言，是给每个人算「此刻想不想说话」的分 |
| 他们会自己发展关系 | `AetherKit/Orchestration/AutonomyScheduler.swift` + `RelationshipEngine.swift` | 五维关系连续量 + 时间衰减 + 幕间私聊。私聊不进聊天列表，只改关系，日后被自然提起 |
| 一键复刻游戏角色 | `AetherCore/Canon/ResearchAgent.swift` | 自己检索萌百/维基/Fandom → 抽事实 → 去重 → 标置信度 → 检测冲突 → 还原语癖 → 交你审核 |

---

## 怎么跑（两条路，按你手上有什么机器选）

### 只有 Windows —— 跑内核测试

内核被拆成了一个独立的 SwiftPM 包 `AetherCore`，**纯 Foundation，零苹果依赖**，
所以它在 Windows 和 Linux 上都能编译、能跑测试。

```powershell
winget install Swift.Toolchain
cd F:\DeepSeek-Harness\workspace\AetherChat
swift test --package-path AetherCore
```

会真的跑起来 34 个测试：演出指令的流式解析、SHA-256 指纹、
人格冻结与防篡改、上下文组装与摘要游标、关系演化与群聊发言权、
以及一整轮离线对话的端到端。

**看不到界面、看不到立绘、听不到声音** —— 那些在外壳里，Windows 上无解。
但"逻辑对不对"这件事，在你自己机器上就能确认。

细节见 [docs/07-无Mac测试.md](docs/07-无Mac测试.md)。

### 有 Mac —— 跑整个 app

```bash
brew install xcodegen
cd AetherChat
make open          # 生成 .xcodeproj 并打开
# 在 Xcode 里选模拟器，⌘R
```

**不需要任何 API Key 就能跑。** 默认引擎是 `MockProvider`（离线演示），
它会让「上下文引擎 → 演出系统 → 关系演化 → 群聊编排」每一环都真实执行一遍，
只是台词是模板。接上真模型后，说话的部分就换成人写的了。

配真实模型：设置页 → 生成引擎 → 选 OpenAI / DeepSeek / 自建兼容 → 填接口地址和密钥。
密钥进 Keychain，不进代码、不进日志、不进任何界面。

### 两者都没有 —— 云端编译

推到一个 GitHub 仓库即可（公开库的 macOS runner 免费且不限时）。
`.github/workflows/` 里有两个 workflow 会自动跑：

- **Core Tests** —— ubuntu / macOS / Windows 三平台跑内核测试
- **iOS Build** —— macOS runner 上 `xcodegen` + `xcodebuild`，编译整包并回传日志

---

## 暗门怎么进

潜意识层没有可见入口。两种进法：

- 聊天界面 **连点标题 5 次**
- 设置页 **长按「灵犀 0.1.0」那一行 3 秒**

然后面容 ID。进去之后能看到：长期记忆、上下文摘要、关系数值、幕间日志、内心独白，
以及最有用的一个按钮 —— **上下文透视**：把「此刻模型实际会收到什么」原样拼出来给你看。

> 为什么要有这个：用户要求它「不显示在明面上」，但**不可观测的上下文管理等于没有上下文管理**。
> 出问题的时候，你必须能看见它到底喂了什么进去。

---

## 工程结构

按一条判据拆分：**这个文件 import 了 SwiftUI / UIKit / AVFoundation / Security / OSLog 吗？**
是 → 外壳；否 → 内核。

```
AetherChat/
├── AetherCore/                 ★ 跨平台内核（SwiftPM 包，Mac / Windows / Linux 都能编）
│   ├── Package.swift
│   ├── Sources/AetherCore/
│   │   ├── Models/             人格 / 消息 / 关系 / 记忆 / 情绪 / 演出指令（纯值类型，零依赖）
│   │   ├── Persistence/        FileStore + WorldStore（actor）
│   │   ├── LLM/                provider 抽象、SSE 流、演出指令流式解析、沉浸守门、离线引擎
│   │   ├── Memory/             上下文引擎、滚动摘要、记忆抽取、离线向量
│   │   ├── Orchestration/      单聊编排、群聊导演、关系引擎
│   │   ├── Canon/              资料抓取、复刻研究员、人格铸造厂
│   │   └── Support/            SHA-256、日志垫片、钥匙串垫片、扩展
│   └── Tests/AetherCoreTests/  6 个测试套件
│
├── AetherKit/                  ☆ 苹果外壳（依赖 AetherCore）
│   ├── Avatar/                 四套形象运行时 + 协调器
│   ├── Effects/                舞台状态、导演（触感、环境音）
│   ├── Voice/                  TTS / STT / 语音消息 / 通话
│   ├── Media/                  影像工作室、媒体仓库
│   ├── Orchestration/          自主性调度（依赖图片生成，故留在外壳）
│   └── Support/Vault.swift     生物识别暗门
│
├── Features/                   ☆ 界面（聊天 / 联系人 / 创造 / 通话 / 潜意识层 / 设置）
├── App/                        ☆ 装配与根视图
├── .github/workflows/          两个 CI：内核测试 + iOS 编译
└── docs/                       设计文档
```

约 1.06 万行 Swift，84 个文件。内核 31 个源文件，外壳 32 个。

---

## 几条设计上的硬规矩

**1. 模型不碰 UI。**
模型输出的是「感觉」（`⟦e:v=0.7,a=0.8⟧`）和「动作名」（`⟦c:avatar.blush⟧`），
永远不是动画参数、不是颜色、不是像素。中间隔着一层导演。
好处是：换引擎、换形象方案、调演出强度，全都不用动 prompt。

**2. 隐藏层是物理隔离的。**
`Message.hidden` 里装着 token 数、检索到的记忆 ID、内心独白、OOC 拦截次数。
聊天界面**拿不到也不想拿**这些字段；只有潜意识层会去读。这不是靠自觉，是靠结构。

**3. 缺素材必须优雅降级。**
3D 模型加载失败 → 退立绘；立绘没有 → 退光核；TTS 没配 → 退系统音；转写失败 → 不影响录音。
任何一个环节出问题都不该让用户看到报错弹窗 —— 那会当场把"她是个真人"这个幻觉打碎。

**4. 演出有边界。**
一条消息的抖动不会晃到整个界面。雨会一直下，脸红只持续两秒 —— 这两类效果在
`StageState` 里被显式区分为「常驻」和「瞬时」。

**5. 内核不许碰苹果。**
这条规矩换来的是：一个只有 Windows 的人也能验证逻辑。为了它，SHA-256 是自己写的、
Keychain 和 Log 做了平台垫片、图片比例参数从 `CGSize` 换成了 `ImageAspect`。

---

## 顺手修掉的一个真 bug

构造内核时发现 `HashingEmbedder` 原来用 `String.hashValue` 取向量桶位：

```swift
let h = abs(gram.sha256Hex.hashValue)   // ← 错在这里
```

Swift 的 `hashValue` **每个进程随机播种**。也就是说同一条记忆，今天算出来的向量和
明天算出来的向量落在完全不同的维度上 —— 持久化的向量检索会静默失效，
而且完全没有任何报错。现在改成从 SHA-256 摘要的前几个字节取桶位与符号，
并加了 `SHA256Tests.testHashIsStableAcrossProcesses` 把它钉住。

---

## 还没做 / 需要你补的

诚实清单：

- **Live2D 需要授权**。Cubism SDK 是闭源商业 SDK，不能随仓库分发。
  `Live2DAvatarRuntime` 已经留好了 `Live2DModelBridge` 协议，你拿到授权后实现它（约 30 行）即可接通。
- **VRM 需要转换**。iOS 侧走 RealityKit，VRM 要先转 USDZ（`VRMKit` + `VRMRealityKit` 或 Blender 批处理）。
  面部驱动用的是「具名部件」约定（`Expr_Happy` / `Mouth_A`），美术侧按约定导出即可。
- **环境音素材没打包**。体积和版权原因。把同名 `.m4a` 丢进 `Bundle/Audio/` 就自动生效。
- **后台自主性是定时器驱动**，真机应该换成 `BGTaskScheduler`（Info.plist 里已经配好标识符）。
- **存储是 JSON**。几万条消息之后该换 GRDB，`WorldStore` 的接口不用动。
- **CallKit 未接入**。当前通话是应用内的。
- **外壳部分仍未编译验证**。内核可以在你机器上验证，但 `Features/` 和 `AetherKit/`
  要等 macOS runner 跑出来才知道。这是实话。

---

## 法律与伦理

- 复刻第三方作品角色，公开分发前请确认该作品的**二次创作条款**。
  自用没问题，上架 App Store 卖就要小心。
- 角色知识库里的每一条设定都带出处链接（`CanonFact.sources`），
  刻意做成可核查的 —— 这既是为了准确性，也是为了在需要时能说清资料从哪来。
- 不要用这套东西冒充真人做诈骗。这句话写在这里，是因为它确实做得到。

---

## 文档

- [docs/01-架构总览.md](docs/01-架构总览.md)
- [docs/02-人格宪章.md](docs/02-人格宪章.md)
- [docs/03-隐藏上下文引擎.md](docs/03-隐藏上下文引擎.md)
- [docs/04-演出系统.md](docs/04-演出系统.md)
- [docs/05-角色复刻.md](docs/05-角色复刻.md)
- [docs/06-路线图.md](docs/06-路线图.md)
- [docs/07-无Mac测试.md](docs/07-无Mac测试.md)  ← Windows 上怎么验证
