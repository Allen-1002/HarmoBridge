import Foundation

/// 外层帧（明文 JSON）。字段按类型可选，见 docs/protocol.md。
public struct Envelope: Codable, Equatable {
    public var t: String
    /// 协议版本（v2 起必带 2）
    public var v: Int?
    public var deviceId: String?
    public var deviceName: String?
    public var macId: String?
    public var macName: String?
    /// v1.1：电脑平台 "mac" / "windows"，旧版手机忽略
    public var platform: String?
    public var pub: String?
    public var nonce: String?
    public var box: String?
    public var code: String?
    /// v2 配对确认码（HMAC，Base64）
    public var confirm: String?

    public init(t: String, v: Int? = nil, deviceId: String? = nil, deviceName: String? = nil, macId: String? = nil,
                macName: String? = nil, platform: String? = nil, pub: String? = nil, nonce: String? = nil,
                box: String? = nil, code: String? = nil, confirm: String? = nil) {
        self.t = t
        self.v = v
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.macId = macId
        self.macName = macName
        self.platform = platform
        self.pub = pub
        self.nonce = nonce
        self.box = box
        self.code = code
        self.confirm = confirm
    }

    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    public static func parse(_ text: String) -> Envelope? {
        try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
    }
}

/// 认证后加密在 box 里的业务消息。
public struct Inner: Codable, Equatable {
    public var kind: String
    public var sid: String
    public var seq: Int
    /// v2：电脑→手机消息的电脑侧递增序号（手机据此防重放）
    public var cseq: Int?
    public var id: String?
    public var bundleName: String?
    public var appName: String?
    public var title: String?
    public var text: String?
    public var time: Double?
    public var test: Bool?
    public var ids: [String]?
    public var result: String?
    public var code: String?
    // kind = "settings"：两端共有的同步开关
    public var paused: Bool?
    public var blockSensitive: Bool?
    public var copyOtp: Bool?
    public var updatedAt: Double?

    public init(kind: String, sid: String, seq: Int, cseq: Int? = nil, id: String? = nil, bundleName: String? = nil,
                appName: String? = nil, title: String? = nil, text: String? = nil, time: Double? = nil,
                test: Bool? = nil, ids: [String]? = nil, result: String? = nil, code: String? = nil,
                paused: Bool? = nil, blockSensitive: Bool? = nil, copyOtp: Bool? = nil, updatedAt: Double? = nil) {
        self.kind = kind
        self.sid = sid
        self.seq = seq
        self.cseq = cseq
        self.id = id
        self.bundleName = bundleName
        self.appName = appName
        self.title = title
        self.text = text
        self.time = time
        self.test = test
        self.ids = ids
        self.result = result
        self.code = code
        self.paused = paused
        self.blockSensitive = blockSensitive
        self.copyOtp = copyOtp
        self.updatedAt = updatedAt
    }

    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    public static func parse(_ text: String) -> Inner? {
        try? JSONDecoder().decode(Inner.self, from: Data(text.utf8))
    }
}

/// 手机发来的一条通知（已解密、已校验）。
public struct MirroredNotification: Equatable, Identifiable {
    public var id: String
    public var bundleName: String
    public var appName: String
    public var title: String
    public var text: String
    public var time: Date
    public var isTest: Bool

    public init(id: String, bundleName: String, appName: String, title: String, text: String, time: Date, isTest: Bool) {
        self.id = id
        self.bundleName = bundleName
        self.appName = appName
        self.title = title
        self.text = text
        self.time = time
        self.isTest = isTest
    }
}

/// 手机发来的验证码（只有验证码本身，没有短信全文）。
public struct OtpCode: Equatable {
    public var id: String
    public var bundleName: String
    public var appName: String
    public var code: String

    public init(id: String, bundleName: String, appName: String, code: String) {
        self.id = id
        self.bundleName = bundleName
        self.appName = appName
        self.code = code
    }
}

/// 两端共有的同步开关。updatedAt 为毫秒时间戳，同步时“后改的为准”。
public struct SharedSettings: Equatable {
    public var paused: Bool
    public var blockSensitive: Bool
    public var copyOtp: Bool
    public var updatedAt: Double

    public init(paused: Bool, blockSensitive: Bool, copyOtp: Bool, updatedAt: Double) {
        self.paused = paused
        self.blockSensitive = blockSensitive
        self.copyOtp = copyOtp
        self.updatedAt = updatedAt
    }

    /// 合并对方的设置：对方更新时返回对方的值，否则保留本机的值。
    public func merged(with remote: SharedSettings) -> SharedSettings {
        remote.updatedAt > updatedAt ? remote : self
    }
}
