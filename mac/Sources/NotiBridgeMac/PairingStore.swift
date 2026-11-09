import CryptoKit
import Foundation
import IOKit
import NotiBridgeCore

/// 已配对手机的密钥：保存在本机加密文件
/// ~/Library/Application Support/com.xsh.notibridge.desktop/pairing.dat（目录 0700、文件 0600）。
///
/// 1.0.3 之前保存在登录钥匙串。自签名应用没有团队 ID，钥匙串只能按每次构建都会变的 cdhash
/// 记录授权，导致每次更新后 macOS 都要为每台手机重新询问。改用文件后不再访问钥匙串。
/// 文件用绑定本机的密钥加密（见 PairingFile），复制到别的电脑无法解密；
/// 但它不能防止以同一用户身份运行的其他程序读取，安全性依赖文件权限和 macOS 的用户隔离。
final class PairingStore: PairedKeyStore {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private let url: URL
    private let fileKey: SymmetricKey
    private var records: [PairingFile.Record] = []
    private let lock = NSLock()
    /// 读取过程中的提示（例如文件损坏），供日志显示
    private(set) var loadProblem: String?
    /// 旧版钥匙串里的密钥被迁移进文件时回调（在调用 key(for:) 的线程上）
    var onLegacyImported: ((String) -> Void)?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xsh.notibridge.desktop", isDirectory: true)
    }

    init(macId: String, directory: URL = PairingStore.directory, machineId: String = PairingStore.machineId()) {
        url = directory.appendingPathComponent("pairing.dat")
        fileKey = PairingFile.fileKey(machineId: machineId, macId: macId)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            records = try PairingFile.open(data, key: fileKey)
        } catch {
            // 无法解密（换了电脑、macId 被清除或文件损坏）：把文件改名保留，不覆盖，配对需要重新进行
            let bad = url.deletingLastPathComponent()
                .appendingPathComponent("pairing.dat.unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: bad)
            loadProblem = "配对文件无法读取（\(error)），已改名为 \(bad.lastPathComponent)，需要重新配对手机"
            records = []
        }
    }

    /// 写入并读回校验。调用方需持有锁。
    @discardableResult
    private func persistLocked() -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try PairingFile.seal(records, key: fileKey)
            try data.write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let back = try PairingFile.open(try Data(contentsOf: url), key: fileKey)
            return back == records
        } catch {
            NSLog("NotiBridge pairing file write failed: \(error)")
            return false
        }
    }

    // MARK: - PairedKeyStore

    func key(for deviceId: String) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        if let r = records.first(where: { $0.id == deviceId }) { return SymmetricKey(data: r.key) }
        // 还没迁移的旧版钥匙串密钥：读出来并移进文件，避免手机被当成“未配对”而删除配对
        guard let legacy = LegacyKeychain.devices().first(where: { $0.id == deviceId }),
              let data = LegacyKeychain.read(deviceId, allowUI: true).data else { return nil }
        records.append(.init(id: deviceId, name: legacy.name, key: data, pairedAt: Date()))
        if persistLocked() { LegacyKeychain.delete(deviceId) }
        onLegacyImported?(legacy.name)
        return SymmetricKey(data: data)
    }

    func save(deviceId: String, name: String, key: SymmetricKey) {
        lock.lock(); defer { lock.unlock() }
        records.removeAll { $0.id == deviceId }
        records.append(.init(id: deviceId, name: name, key: key.withUnsafeBytes { Data($0) }, pairedAt: Date()))
        if !persistLocked() { NSLog("NotiBridge: 保存配对失败") }
    }

    func remove(deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        records.removeAll { $0.id == deviceId }
        persistLocked()
        LegacyKeychain.delete(deviceId)
    }

    // MARK: - 其他

    func devices() -> [Device] {
        lock.lock(); defer { lock.unlock() }
        return records.map { Device(id: $0.id, name: $0.name) }
    }

    /// 导入旧版钥匙串读出的密钥（已存在的跳过），写入并校验成功返回 true
    func importLegacy(_ items: [(id: String, name: String, key: Data)]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for item in items where !records.contains(where: { $0.id == item.id }) {
            records.append(.init(id: item.id, name: item.name, key: item.key, pairedAt: Date()))
        }
        return persistLocked()
    }

    /// 删除配对文件和旧版钥匙串里的所有密钥。返回删除前的配对数。
    @discardableResult
    func removeAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = Set(records.map(\.id)).union(LegacyKeychain.devices().map(\.id)).count
        records = []
        try? FileManager.default.removeItem(at: url)
        LegacyKeychain.removeAll()
        return count
    }

    /// 本机硬件 UUID（IOPlatformUUID），用于把配对文件绑定到这台电脑
    static func machineId() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "unknown-machine" }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return value ?? "unknown-machine"
    }
}
