import AetherCore
import Foundation
import LocalAuthentication

/// 「潜意识层」的暗门。
/// 用户要求：上下文管理不能在明面上存在，但必须真的存在 —— 于是它被放进一道需要生物识别的门后。
enum Vault {
    static var biometryKind: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "光学 ID"
        default: return "设备密码"
        }
    }

    static func unlock(reason: String = "进入潜意识层") async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "使用设备密码"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.app.error("Vault unavailable: \(error?.localizedDescription ?? "-")")
            return false
        }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            Log.app.error("Vault denied: \(error.localizedDescription)")
            return false
        }
    }
}
