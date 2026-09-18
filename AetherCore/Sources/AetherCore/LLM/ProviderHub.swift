import Foundation

/// 服务商中枢：设置一变，这里重建所有 provider，其余代码无感。
/// Key 永远从 Keychain 取，绝不出现在任何日志或界面里。
final class ProviderHub: @unchecked Sendable {
    static let shared = ProviderHub()

    /// 「远程引擎」的工厂。
    ///
    /// 内核不知道远程是什么 —— 那是平台能力（要走桥接、要看有没有配对）。
    /// 外壳在启动时把工厂塞进来；工厂返回 nil 表示当前不可用，
    /// 这时自动退回离线引擎，而不是让聊天直接报错。
    static var remoteProviderFactory: (() -> LLMProvider?)?

    private(set) var llm: LLMProvider = MockProvider()
    private(set) var image: ImageProvider?
    private(set) var embedder: EmbeddingProvider = HashingEmbedder()

    private init() {}

    func rebuild(settings: AppSettings) {
        let key = Keychain.get("llm.apiKey") ?? ""

        switch settings.providerID {
        case "mock":
            llm = MockProvider()
        case "remote":
            llm = ProviderHub.remoteProviderFactory?() ?? MockProvider()
        case "openai", "deepseek", "custom":
            llm = OpenAICompatibleProvider(
                id: settings.providerID,
                displayName: settings.providerID == "deepseek" ? "DeepSeek" : "OpenAI 兼容接口",
                baseURL: settings.baseURL,
                apiKey: key
            )
        default:
            llm = MockProvider()
        }

        image = key.isEmpty ? nil : OpenAIImageProvider(
            baseURL: settings.baseURL, apiKey: key, model: settings.imageModel
        )
        embedder = key.isEmpty
            ? HashingEmbedder()
            : OpenAIEmbeddingProvider(baseURL: settings.baseURL, apiKey: key, model: settings.embeddingModel)

        Log.llm.info("ProviderHub rebuilt: \(self.llm.id), embedder=\(key.isEmpty ? "hashing" : "openai")")
    }

    /// 是否在用离线演示引擎。
    ///
    /// 界面靠它决定要不要提示「复刻质量会下降」——
    /// 判据必须是「真的没有模型」，而不是「用户没选过服务」。
    var isOfflineDemo: Bool { llm.id == "mock" }
}
