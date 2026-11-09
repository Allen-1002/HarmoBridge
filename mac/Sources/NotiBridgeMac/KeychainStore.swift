import CryptoKit
import Foundation
import NotiBridgeCore
import Security

/// 已配对手机的密钥保存在登录钥匙串（通用密码项），account = 手机 deviceId。
final class KeychainStore: PairedKeyStore {
    private let service = "com.xsh.notibridge.mac.paired"

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    func key(for deviceId: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func save(deviceId: String, name: String, key: SymmetricKey) {
        remove(deviceId: deviceId)
        let data = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecAttrLabel as String: "NotiBridge: \(name)",
            kSecAttrDescription as String: name,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("NotiBridge keychain save failed: \(status)")
        }
    }

    func remove(deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 删除本应用写入的所有钥匙串项（所有已配对手机的密钥）。返回删除前的条目数。
    @discardableResult
    func removeAll() -> Int {
        let count = devices().count
        for svc in [service, "com.xsh.notibridge.paired", "com.xsh.notibridge.desktop.paired"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
            ]
            // macOS 上 SecItemDelete 每次可能只删一项，循环到删完为止
            var guardCount = 0
            while SecItemDelete(query as CFDictionary) == errSecSuccess && guardCount < 1000 { guardCount += 1 }
        }
        return count
    }

    func devices() -> [Device] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            let name = item[kSecAttrDescription as String] as? String ?? account
            return Device(id: account, name: name)
        }
    }
}
