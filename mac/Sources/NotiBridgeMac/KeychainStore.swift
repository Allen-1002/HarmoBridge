import Foundation
import Security

/// 1.0.2 及之前版本把配对密钥保存在登录钥匙串（通用密码项，account = 手机 deviceId）。
/// 现在只用于把旧密钥一次性迁移到 PairingStore 的加密文件，以及清除数据时删除残留项。
enum LegacyKeychain {
    static let service = "com.xsh.notibridge.mac.paired"
    /// 更早版本用过的 service 名，清除数据时一并删除
    static let allServices = [service, "com.xsh.notibridge.paired", "com.xsh.notibridge.desktop.paired"]

    /// 只读属性（不读密钥本身），不会触发钥匙串授权询问
    static func devices() -> [PairingStore.Device] {
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
            return PairingStore.Device(id: account, name: name)
        }
    }

    /// 读取密钥。allowUI 为 false 时不弹授权框：需要授权时返回 errSecInteractionNotAllowed。
    static func read(_ deviceId: String, allowUI: Bool) -> (data: Data?, status: OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !allowUI { SecKeychainSetUserInteractionAllowed(true) } }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else { return (nil, status) }
        return (data, status)
    }

    @discardableResult
    static func delete(_ deviceId: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func removeAll() {
        for svc in allServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
            ]
            // macOS 上 SecItemDelete 每次可能只删一项，循环到删完为止
            var guardCount = 0
            while SecItemDelete(query as CFDictionary) == errSecSuccess && guardCount < 1000 { guardCount += 1 }
        }
    }
}
