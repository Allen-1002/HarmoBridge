import Foundation

/// ESP32 固件串口协议（docs/esp32-serial.md）的事件解析。与 Windows 端 Esp32Link.cs 一致。
/// 固件输出的每一行：`HB-ESP32 <版本> ...` 是握手回复，`@{json}` 是事件，其他行是日志，忽略。
public enum Esp32Event: Equatable {
    case hello(version: String, bleAddress: String, proto: Int)
    case state(Esp32LinkState)
    case bonds([PairedIphone])
    case notification(IphoneNotification)
    case removed(uid: UInt32)
    case acted(uid: UInt32, action: Int)
    case error(code: String, message: String)
}

public struct Esp32LinkState: Equatable {
    /// idle / advertising / connected / encrypted / ready
    public var ble: String
    public var peer: String
    public var bonds: Int
    public var pairing: Bool

    public init(ble: String, peer: String, bonds: Int, pairing: Bool) {
        self.ble = ble
        self.peer = peer
        self.bonds = bonds
        self.pairing = pairing
    }

    public var label: String {
        switch ble {
        case "ready": return "iPhone 已连接"
        case "encrypted", "connected": return "iPhone 正在连接…"
        case "advertising": return bonds > 0 ? "等待 iPhone 连接" : "等待 iPhone 配对"
        default: return "蓝牙未就绪"
        }
    }
}

/// ESP32 上配对过的一台 iPhone
public struct PairedIphone: Identifiable, Equatable {
    /// 蓝牙地址（aa:bb:cc:dd:ee:ff），固定不变
    public var id: String
    /// iPhone 自己的设备名，例如“Allen 的 iPhone”；第一次连上之前可能为空
    public var name: String
    public var connected: Bool
    /// 已订阅通知，可以收通知
    public var ancsReady: Bool

    public init(id: String, name: String, connected: Bool, ancsReady: Bool) {
        self.id = id
        self.name = name
        self.connected = connected
        self.ancsReady = ancsReady
    }

    public var displayName: String { name.isEmpty ? "iPhone" : name }
}

public struct IphoneNotification: Equatable {
    public static let flagSilent = 1
    public static let flagImportant = 2
    public static let flagPreExisting = 4

    public var uid: UInt32
    public var modified: Bool
    public var flags: Int
    public var category: Int
    public var appId: String
    public var appName: String
    public var title: String
    public var subtitle: String
    public var message: String
    /// ANCS 日期 yyyyMMdd'T'HHmmSS（iPhone 本地时间）
    public var date: String
    public var positiveLabel: String
    public var negativeLabel: String

    /// 连接时 iPhone 补发的已有通知（不弹出，只记录）
    public var preExisting: Bool { flags & Self.flagPreExisting != 0 }
    public var silent: Bool { flags & Self.flagSilent != 0 }

    /// 来电（ANCS 类别 1）与未接来电（2）
    public var isIncomingCall: Bool { category == 1 }

    /// 转成电脑端统一的通知结构
    public func mirrored(now: Date = Date()) -> MirroredNotification {
        let text = subtitle.isEmpty ? message : (message.isEmpty ? subtitle : "\(subtitle)\n\(message)")
        return MirroredNotification(id: "ios-\(uid)", bundleName: appId,
                                    appName: appName.isEmpty ? appId : appName,
                                    title: title, text: text, time: parsedDate ?? now, isTest: false)
    }

    public var parsedDate: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: date)
    }
}

public enum Esp32LinkParser {
    public static func parse(line raw: String) -> Esp32Event? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("HB-ESP32 ") {
            let parts = line.split(separator: " ")
            var kv: [String: String] = [:]
            for p in parts.dropFirst(2) {
                let pair = p.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { kv[String(pair[0])] = String(pair[1]) }
            }
            return .hello(version: parts.count > 1 ? String(parts[1]) : "?", bleAddress: kv["ble"] ?? "",
                          proto: Int(kv["proto"] ?? "") ?? 0)
        }
        guard line.hasPrefix("@{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst().utf8)) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        func s(_ k: String) -> String { obj[k] as? String ?? "" }
        func i(_ k: String) -> Int { (obj[k] as? NSNumber)?.intValue ?? 0 }
        func u(_ k: String) -> UInt32? {
            guard let n = obj[k] as? NSNumber, n.int64Value >= 0, n.int64Value <= Int64(UInt32.max) else { return nil }
            return UInt32(n.int64Value)
        }
        switch t {
        case "state":
            return .state(Esp32LinkState(ble: s("ble"), peer: s("peer"), bonds: i("bonds"),
                                         pairing: obj["pairing"] as? Bool ?? false))
        case "notif":
            guard let uid = u("uid") else { return nil }
            return .notification(IphoneNotification(
                uid: uid, modified: s("ev") == "mod", flags: i("flags"), category: i("cat"), appId: s("app"),
                appName: s("appName"), title: s("title"), subtitle: s("sub"), message: s("msg"), date: s("date"),
                positiveLabel: s("pos"), negativeLabel: s("neg")))
        case "bonds":
            let list = obj["list"] as? [[String: Any]] ?? []
            return .bonds(list.compactMap { b in
                guard let addr = b["addr"] as? String, !addr.isEmpty else { return nil }
                return PairedIphone(id: addr, name: b["name"] as? String ?? "", connected: b["connected"] as? Bool ?? false,
                                    ancsReady: b["ready"] as? Bool ?? false)
            })
        case "removed":
            guard let uid = u("uid") else { return nil }
            return .removed(uid: uid)
        case "acted":
            guard let uid = u("uid") else { return nil }
            return .acted(uid: uid, action: i("action"))
        case "err":
            return .error(code: s("code"), message: s("msg"))
        default:
            return nil
        }
    }
}

/// 把串口字节流切成行（固件按 \n 结尾）。
public struct LineSplitter {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer += bytes
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[..<nl], as: UTF8.self))
            buffer.removeSubrange(...nl)
        }
        // 防止没有换行的乱码无限增长
        if buffer.count > 16384 { buffer.removeAll() }
        return lines
    }
}
