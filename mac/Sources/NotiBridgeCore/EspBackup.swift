import CryptoKit
import Foundation

/// 刷写前自动备份板子上原有的固件，之后可以一键还原。与 Windows 端 EspBackup.cs 一致。
///
/// - 每块板子（按芯片出厂 MAC 区分）只备份一次：第一次刷写 NotiBridge 之前的内容就是“原固件”。
///   板子上已经是 NotiBridge 固件时不再备份，避免覆盖真正的原固件。
/// - 备份整块闪存；全是 0xFF 的 64KB 块用芯片内 MD5 判断后跳过，不必逐字节读取。
/// - NotiBridge 只会改动 [0x1000, touchedEnd)：ROM 写入的范围，以及固件运行时写的 NVS（在这个范围内）。
///   还原时只写回这一段，其余部分本来就没动过。
public struct EspBackupInfo: Codable, Equatable {
    public var mac: String
    public var createdAt: Date
    public var flashSize: UInt32
    /// 备份文件的 SHA-256
    public var sha256: String
    /// NotiBridge 写过的最远位置（不含）
    public var touchedEnd: UInt32
    /// 备份时板子上看起来是空的（全 0xFF）
    public var wasBlank: Bool
}

public final class EspBackupStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    static func fileName(_ mac: String) -> String { mac.replacingOccurrences(of: ":", with: "") }

    public func imageURL(mac: String) -> URL { directory.appendingPathComponent("\(Self.fileName(mac)).bin") }
    public func infoURL(mac: String) -> URL { directory.appendingPathComponent("\(Self.fileName(mac)).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func info(mac: String) -> EspBackupInfo? {
        guard let data = try? Data(contentsOf: infoURL(mac: mac)) else { return nil }
        return try? Self.decoder.decode(EspBackupInfo.self, from: data)
    }

    /// 所有备份（新的在前）
    public func all() -> [EspBackupInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(EspBackupInfo.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(image: [UInt8], info: EspBackupInfo) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(image).write(to: imageURL(mac: info.mac), options: .atomic)
        try saveInfo(info)
    }

    public func saveInfo(_ info: EspBackupInfo) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(info).write(to: infoURL(mac: info.mac), options: .atomic)
    }

    /// 读取备份并核对 SHA-256
    public func load(mac: String) throws -> (EspBackupInfo, [UInt8]) {
        guard let info = info(mac: mac) else { throw EspFlashError.badImage("这块板子没有备份") }
        let data = try Data(contentsOf: imageURL(mac: mac))
        guard Self.sha256(data) == info.sha256, data.count == Int(info.flashSize) else {
            throw EspFlashError.badImage("备份文件已损坏")
        }
        return (info, [UInt8](data))
    }

    public func delete(mac: String) {
        try? FileManager.default.removeItem(at: imageURL(mac: mac))
        try? FileManager.default.removeItem(at: infoURL(mac: mac))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 刷写 / 还原流程（含自动备份）。
public enum EspFirmwareInstaller {
    public static let firmwareOffset: UInt32 = 0x1000
    static let appOffset: UInt32 = 0x10000
    /// NVS（iPhone 配对保存在这里）与 phy_init 分区：[0x9000, 0x10000)
    static let nvsOffset: UInt32 = 0x9000
    static let projectName = "notibridge_esp32"
    static let blockSize = 64 * 1024

    public enum BackupOutcome: Equatable {
        /// 这次刷写前新建了备份
        case created
        /// 已经有这块板子的备份，保留不动
        case kept
        /// 板子上已经是 NotiBridge 固件，没有原固件可备份
        case alreadyNotiBridge
    }

    /// 板子上的应用是不是 NotiBridge 固件（读 esp_app_desc_t 的 project_name）
    static func hasNotiBridgeFirmware(_ f: EspFlasher) throws -> Bool {
        // 镜像头 24 字节 + 段头 8 字节之后是 esp_app_desc_t：magic(4) ... project_name 在 +0x30
        let d = try f.read(offset: appOffset + 0x20, length: 0x50)
        let magic = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
        guard magic == 0xABCD_5432 else { return false }
        let name = d[0x30..<0x50].prefix { $0 != 0 }
        return String(decoding: name, as: UTF8.self) == projectName
    }

    /// 读整块闪存，跳过全 0xFF 的块
    static func readAll(_ f: EspFlasher, flashSize: UInt32, progress: @escaping (Double) -> Void) throws -> (image: [UInt8], blank: Bool) {
        let emptyMd5 = EspFlasher.md5Hex([UInt8](repeating: 0xFF, count: blockSize))
        var image = [UInt8](repeating: 0xFF, count: Int(flashSize))
        let blocks = Int(flashSize) / blockSize
        var nonEmpty: [Int] = []
        for b in 0..<blocks where try f.md5(offset: UInt32(b * blockSize), length: blockSize) != emptyMd5 {
            nonEmpty.append(b)
        }
        for (i, b) in nonEmpty.enumerated() {
            let data = try f.read(offset: UInt32(b * blockSize), length: blockSize) { p in
                progress((Double(i) + p) / Double(nonEmpty.count))
            }
            image.replaceSubrange((b * blockSize)..<((b + 1) * blockSize), with: data)
        }
        return (image, nonEmpty.isEmpty)
    }

    /// 刷写固件。第一次刷写某块板子时先备份原固件。
    @discardableResult
    public static func install(image: [UInt8], port: EspSerialTransport, store: EspBackupStore,
                               onStage: ((EspFlasher.Stage) -> Void)? = nil, log: ((String) -> Void)? = nil,
                               resetDelay: TimeInterval = 0.1) throws -> BackupOutcome {
        let f = EspFlasher(port: port)
        f.resetDelay = resetDelay
        f.onStage = onStage
        f.log = log
        try f.begin()
        let mac = try f.readMac()
        let end = firmwareOffset + UInt32(image.count)
        let isNotiBridge = try hasNotiBridgeFirmware(f)
        let outcome: BackupOutcome
        if var info = store.info(mac: mac) {
            // 记录写过的最远位置，还原时覆盖到这里
            if end > info.touchedEnd {
                info.touchedEnd = end
                try store.saveInfo(info)
            }
            outcome = .kept
        } else if isNotiBridge {
            outcome = .alreadyNotiBridge
        } else {
            onStage?(.backingUp(0))
            let (backup, blank) = try readAll(f, flashSize: f.flashSize) { onStage?(.backingUp($0)) }
            let info = EspBackupInfo(mac: mac, createdAt: Date(), flashSize: f.flashSize,
                                     sha256: EspBackupStore.sha256(Data(backup)), touchedEnd: end, wasBlank: blank)
            try store.save(image: backup, info: info)
            log?("已备份板子 \(mac) 的原固件")
            outcome = .created
        }
        let nvsStart = Int(nvsOffset - firmwareOffset), nvsEnd = Int(appOffset - firmwareOffset)
        if isNotiBridge && image.count > nvsEnd {
            // 更新 NotiBridge 固件：跳过 NVS 和 phy_init 分区，保留 iPhone 配对
            try f.write(image: Array(image[0..<nvsStart]), offset: firmwareOffset)
            try f.write(image: Array(image[nvsEnd...]), offset: appOffset)
        } else {
            try f.write(image: image, offset: firmwareOffset)
        }
        try f.finish()
        return outcome
    }

    /// 还原原固件：只写回 NotiBridge 改动过的 [0x1000, touchedEnd)。
    public static func restore(port: EspSerialTransport, store: EspBackupStore,
                               onStage: ((EspFlasher.Stage) -> Void)? = nil, log: ((String) -> Void)? = nil,
                               resetDelay: TimeInterval = 0.1) throws -> EspBackupInfo {
        let f = EspFlasher(port: port)
        f.resetDelay = resetDelay
        f.onStage = onStage
        f.log = log
        try f.begin()
        let mac = try f.readMac()
        let (info, backup) = try store.load(mac: mac)
        // 按 4KB 扇区对齐
        let end = min(Int(info.flashSize), (Int(info.touchedEnd) + 0xFFF) & ~0xFFF)
        try f.write(image: Array(backup[Int(firmwareOffset)..<end]), offset: firmwareOffset)
        try f.finish()
        log?("已把板子 \(mac) 还原为原固件")
        return info
    }
}
