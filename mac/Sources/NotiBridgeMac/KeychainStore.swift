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

    /// 内存缓存：启动时一次性读出所有密钥，之后连接手机不再访问钥匙串（避免使用中途弹出钥匙串授权框）。
    /// 由 BridgeServer 的连接线程和主线程共同访问，用锁保护。
    private var cache: [String: SymmetricKey] = [:]
    private let lock = NSLock()

    func key(for deviceId: String) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        if let k = cache[deviceId] { return k }
        guard let k = read(deviceId, allowUI: true).key else { return nil }
        cache[deviceId] = k
        return k
    }

    /// 读取前先静默试一次：返回 true 表示有密钥需要 macOS 询问钥匙串权限（例如应用签名变了）。
    func needsAuthorization() -> Bool {
        lock.lock(); defer { lock.unlock() }
        for d in devices() where cache[d.id] == nil {
            let r = read(d.id, allowUI: false)
            if let k = r.key { cache[d.id] = k } else if r.status == errSecInteractionNotAllowed { return true }
        }
        return false
    }

    /// 一次性把所有已配对手机的密钥读入缓存；如需授权，macOS 会在这里（启动时）逐项询问。
    func preloadAll() {
        for d in devices() { _ = key(for: d.id) }
    }

    private func read(_ deviceId: String, allowUI: Bool) -> (key: SymmetricKey?, status: OSStatus) {
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
        return (SymmetricKey(data: data), status)
    }

    func save(deviceId: String, name: String, key: SymmetricKey) {
        remove(deviceId: deviceId)
        lock.lock(); cache[deviceId] = key; lock.unlock()
        let data = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecAttrLabel as String: "NotiBridge 配对密钥：\(name)",
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
        lock.lock(); cache.removeValue(forKey: deviceId); lock.unlock()
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
        lock.lock(); cache.removeAll(); lock.unlock()
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
