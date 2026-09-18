import Foundation

#if canImport(Security)
import Security

/// 苹果平台：API Key 只进系统钥匙串。
/// 不落盘明文、不进聊天界面、不同步到任何服务器。
enum Keychain {
    private static let service = "com.aether.chat.secrets"

    static func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#else

/// 非苹果平台：没有钥匙串。
///
/// 退化成进程内的内存字典 —— 够跑测试，够让 ProviderHub 编译。
/// **这不是一个安全的实现，只是让内核可移植的垫片。**
/// 真机永远走上面那个分支。
enum Keychain {
    private static let lock = NSLock()
    private static var storage: [String: String] = [:]

    static func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    static func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    /// 仅供测试断言用
    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

#endif
