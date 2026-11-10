import Foundation

/// ESP32 固件串口协议（docs/esp32-serial.md）的事件解析。与 Windows 端 Esp32Link.cs 一致。
/// 固件输出的每一行：`HB-ESP32 <版本> ...` 是握手回复，`@{json}` 是事件，其他行是日志，忽略。
public enum Esp32Event: Equatable {
    case hello(version: String, bleAddress: String, proto: Int)
    case state(Esp32LinkState)
    case bonds([PairedIphone])
    case notification(IphoneNotification)
    /// peer：发来的 iPhone 地址（固件 1.2.3 起；旧固件为空）
    case removed(uid: UInt32, peer: String)
    case acted(uid: UInt32, action: Int)
    case error(code: String, message: String)
    /// 免提（HFP）连接状态
    case hfp(HfpLink)
    /// 通话状态
    case call(PhoneCall)
    /// ESP32 上配对过的手机（经典蓝牙，用于通话）
    case phones([PairedPhone])
    /// 手机蓝牙配对时显示的 6 位数字（与手机上显示的应一致）
    case pairCode(String)
    case callWaiting(number: String)
}

/// 免提连接（ESP32 ↔ 手机的经典蓝牙 HFP）
public struct HfpLink: Equatable {
    /// disconnected / connecting / connected / disconnecting
    public var state: String
    public var peer: String
    public var name: String
    /// off / connecting / cvsd（8 kHz）/ msbc（16 kHz）
    public var audio: String
    /// 通话声音走电脑（pc）还是留在手机上（phone）
    public var audioToPC: Bool
    public var battery: Int
    public var signal: Int
    public var networkOperator: String
    public var discoverable: Bool

    public init(state: String, peer: String, name: String, audio: String, audioToPC: Bool, battery: Int, signal: Int,
                networkOperator: String, discoverable: Bool) {
        self.state = state
        self.peer = peer
        self.name = name
        self.audio = audio
        self.audioToPC = audioToPC
        self.battery = battery
        self.signal = signal
        self.networkOperator = networkOperator
        self.discoverable = discoverable
    }

    public var connected: Bool { state == "connected" }
}

/// 通话状态
public struct PhoneCall: Equatable {
    /// idle / incoming（来电）/ dialing（呼出）/ alerting（对方振铃）/ active（通话中）
    public var state: String
    public var number: String
    public var held: Int

    public init(state: String, number: String, held: Int) {
        self.state = state
        self.number = number
        self.held = held
    }

    public static let idle = PhoneCall(state: "idle", number: "", held: 0)
    public var isIdle: Bool { state == "idle" }
    public var label: String {
        switch state {
        case "incoming": return "来电"
        case "dialing": return "正在呼叫"
        case "alerting": return "对方振铃中"
        case "active": return held > 0 ? "通话保持中" : "通话中"
        default: return "空闲"
        }
    }
}

/// 配对过的手机（经典蓝牙）
public struct PairedPhone: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var connected: Bool

    public init(id: String, name: String, connected: Bool) {
        self.id = id
        self.name = name
        self.connected = connected
    }

    public var displayName: String { name.isEmpty ? "手机" : name }
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
    /// 发来通知的 iPhone 地址（对应 PairedIphone.id；固件 1.2.3 起才有）
    public var peer: String = ""

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
                positiveLabel: s("pos"), negativeLabel: s("neg"), peer: s("peer")))
        case "bonds":
            let list = obj["list"] as? [[String: Any]] ?? []
            return .bonds(list.compactMap { b in
                guard let addr = b["addr"] as? String, !addr.isEmpty else { return nil }
                return PairedIphone(id: addr, name: b["name"] as? String ?? "", connected: b["connected"] as? Bool ?? false,
                                    ancsReady: b["ready"] as? Bool ?? false)
            })
        case "hfp":
            return .hfp(HfpLink(state: s("state"), peer: s("peer"), name: s("name"), audio: s("audio"),
                                audioToPC: s("audioTo") == "pc", battery: (obj["battery"] as? NSNumber)?.intValue ?? -1,
                                signal: (obj["signal"] as? NSNumber)?.intValue ?? -1, networkOperator: s("operator"),
                                discoverable: obj["discoverable"] as? Bool ?? false))
        case "call":
            return .call(PhoneCall(state: s("state").isEmpty ? "idle" : s("state"), number: s("number"), held: i("held")))
        case "phones":
            let list = obj["list"] as? [[String: Any]] ?? []
            return .phones(list.compactMap { b in
                guard let addr = b["addr"] as? String, !addr.isEmpty else { return nil }
                return PairedPhone(id: addr, name: b["name"] as? String ?? "", connected: b["connected"] as? Bool ?? false)
            })
        case "pair_code":
            return .pairCode(s("code"))
        case "call_waiting":
            return .callWaiting(number: s("number"))
        case "removed":
            guard let uid = u("uid") else { return nil }
            return .removed(uid: uid, peer: s("peer"))
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
