import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    /// 跨平台的 async 请求包装。
    ///
    /// 为什么不用 URLSession.data(for:)：那个 async 重载在 Linux 的
    /// swift-corelibs-foundation 上并不存在（只有 dataTask + completionHandler），
    /// 用了它整个内核包在 ubuntu 上就编不过 —— 而我们正是靠 ubuntu 来跑逻辑测试的。
    /// 用 continuation 包一层，三个平台行为一致。
    func aetherData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: LLMError.empty)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    func aetherData(from url: URL) async throws -> (Data, URLResponse) {
        try await aetherData(for: URLRequest(url: url))
    }
}
