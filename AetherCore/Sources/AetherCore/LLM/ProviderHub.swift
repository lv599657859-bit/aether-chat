import Foundation

/// 服务商中枢：设置一变，这里重建所有 provider，其余代码无感。
/// Key 永远从 Keychain 取，绝不出现在任何日志或界面里。
final class ProviderHub: @unchecked Sendable {
    static let shared = ProviderHub()

    private(set) var llm: LLMProvider = MockProvider()
    private(set) var image: ImageProvider?
    private(set) var embedder: EmbeddingProvider = HashingEmbedder()

    private init() {}

    func rebuild(settings: AppSettings) {
        let key = Keychain.get("llm.apiKey") ?? ""

        switch settings.providerID {
        case "mock":
            llm = MockProvider()
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

    var isOfflineDemo: Bool { llm.id == "mock" }
}
