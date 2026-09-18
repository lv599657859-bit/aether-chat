import Foundation

/// 全局设置。隐私相关的一切都收在「潜意识层」里，主界面一个字都不出现。
struct AppSettings: Codable, Sendable {
    // MARK: 沉浸
    /// 沉浸守门：过滤一切元语言（AI / 模型 / 提示词 / 上下文）
    var immersionGuardEnabled = true
    /// 用「正在斟酌…」代替「正在生成」
    var characterfulThinking = true
    /// 允许角色主动发消息
    var autonomyEnabled = true
    /// 允许角色发日常照片
    var dailyShareEnabled = true
    /// 允许角色之间私聊并发展关系
    var interCharacterChatterEnabled = true
    /// 演出强度：0 克制 … 1 张扬
    var performanceIntensity: Double = 0.6
    var reduceMotion = false

    // MARK: 暗门
    /// 潜意识层入口是否常显（默认关闭 -> 长按标题 3 秒开启）
    var subconsciousEntryVisible = false
    var vaultBiometryRequired = true
    /// 上下文管理开关（用户要求：不显示，但必须存在）
    var contextEngineEnabled = true
    var autoSummarizeThreshold = 6000
    var retrievalTopK = 6
    var keepInnerMonologue = true

    // MARK: 模型
    var providerID = "mock"
    var chatModel = "gpt-4o-mini"
    var imageModel = "gpt-image-1"
    var ttsModel = "tts-1"
    var sttModel = "whisper-1"
    var embeddingModel = "text-embedding-3-small"
    var baseURL = "https://api.openai.com/v1"
    var temperature: Double = 0.9
    var maxTokens = 900

    // MARK: 隐私
    var localOnlyMemory = true
    var crashReportsEnabled = false

    static let standard = AppSettings()
}
