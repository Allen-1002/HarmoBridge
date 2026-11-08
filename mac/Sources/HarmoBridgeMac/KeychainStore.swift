import CryptoKit
import Foundation
import HarmoBridgeCore
import Security

/// 已配对手机的密钥保存在登录钥匙串（通用密码项），account = 手机 deviceId。
final class KeychainStore: PairedKeyStore {
    private let service = "com.xsh.harmobridge.mac.paired"

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
            kSecAttrLabel as String: "HarmoBridge: \(name)",
            kSecAttrDescription as String: name,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("HarmoBridge keychain save failed: \(status)")
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
