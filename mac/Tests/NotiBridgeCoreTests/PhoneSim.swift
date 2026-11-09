import CryptoKit
import Foundation
@testable import NotiBridgeCore

/// 按协议 v2 模拟手机端（测试用，不是真机）。
final class PhoneSim {
    let deviceId: String
    let name: String
    let platform: String
    var key: SymmetricKey?
    var phoneNonce = Data()
    var ya = Data()
    var yaPub = Data()
    var keys: BridgeCrypto.PairingKeys?
    var sid = ""
    var seq = 0
    var authNonce = ""
    var lastCseq = 0

    init(deviceId: String, name: String = "Phone", platform: String = "android") {
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
    }

    func pairReq(version: Int? = 2) -> String {
        phoneNonce = BridgeCrypto.randomBytes(16)
        return Envelope(t: "pair_req", v: version, deviceId: deviceId, deviceName: name, platform: platform,
                        nonce: phoneNonce.base64EncodedString()).json()
    }

    /// 收到 pair_chal 后：按 PIN 算 g、Ya、K，返回 pair_key 帧
    func pairKey(_ chal: Envelope, pin: String, scalar: Data? = nil) throws -> String {
        let ctx = BridgeCrypto.PairingContext(
            deviceId: deviceId, deviceName: name, phonePlatform: platform, macId: chal.macId ?? "",
            macName: chal.macName ?? "", macPlatform: chal.platform ?? "", phoneNonce: phoneNonce,
            macNonce: Data(base64Encoded: chal.nonce ?? "") ?? Data())
        ya = scalar ?? BridgeCrypto.randomBytes(32)
        yaPub = try Cpace.scalarMultVfy(scalar: ya, point: ctx.generator(pin: pin))
        let yb = Data(base64Encoded: chal.pub ?? "") ?? Data()
        let k = try Cpace.scalarMultVfy(scalar: ya, point: yb)
        keys = BridgeCrypto.pairingKeys(k: k, context: ctx, ya: yaPub, yb: yb)
        return Envelope(t: "pair_key", pub: yaPub.base64EncodedString()).json()
    }

    func pairConfirm() -> String {
        Envelope(t: "pair_confirm", confirm: keys!.confirmPhone.base64EncodedString()).json()
    }

    /// 核对电脑的确认码，通过才“保存”密钥
    func acceptPairOk(_ env: Envelope) -> Bool {
        guard env.t == "pair_ok", let c = env.confirm.flatMap({ Data(base64Encoded: $0) }), let keys,
              BridgeCrypto.constantTimeEqual(c, keys.confirmComputer) else { return false }
        key = keys.pairKey
        return true
    }

    func hello(version: Int? = 2) -> String {
        authNonce = BridgeCrypto.randomBytes(16).base64EncodedString()
        return Envelope(t: "hello", v: version, deviceId: deviceId, nonce: authNonce).json()
    }

    func auth(_ challenge: Envelope) throws -> String {
        sid = challenge.nonce ?? ""
        seq = 0
        lastCseq = 0
        return Envelope(t: "auth", box: try BridgeCrypto.seal(key!, "auth|\(authNonce)|\(sid)", .toComputer)).json()
    }

    func checkAuthOk(_ env: Envelope) -> Bool {
        guard env.t == "auth_ok", let box = env.box,
              let plain = try? BridgeCrypto.open(key!, box, .toPhone) else { return false }
        return plain == "ok|\(sid)|\(authNonce)"
    }

    func msg(_ inner: Inner) throws -> String {
        Envelope(t: "msg", box: try BridgeCrypto.seal(key!, inner.json(), .toComputer)).json()
    }

    func notify(_ id: String, title: String = "t", text: String = "x") throws -> String {
        seq += 1
        return try msg(Inner(kind: "notify", sid: sid, seq: seq, id: id, bundleName: "com.a", appName: "A",
                             title: title, text: text, time: 1_700_000_000_000, test: false))
    }

    /// 手机端对电脑消息的校验：sid 一致、cseq 严格递增；不通过返回 nil
    func receive(_ env: Envelope) -> Inner? {
        guard env.t == "msg", let box = env.box, let plain = try? BridgeCrypto.open(key!, box, .toPhone),
              let inner = Inner.parse(plain), inner.sid == sid, let c = inner.cseq, c > lastCseq else { return nil }
        lastCseq = c
        return inner
    }
}

final class MemoryStore: PairedKeyStore {
    var keys: [String: SymmetricKey] = [:]
    let lock = NSLock()
    func key(for deviceId: String) -> SymmetricKey? { lock.lock(); defer { lock.unlock() }; return keys[deviceId] }
    func save(deviceId: String, name: String, key: SymmetricKey) { lock.lock(); keys[deviceId] = key; lock.unlock() }
    func remove(deviceId: String) { lock.lock(); keys.removeValue(forKey: deviceId); lock.unlock() }
}

func hexData(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// docs/test-vectors/pairing-v2.json（四端共用）
func loadVectors() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/test-vectors/pairing-v2.json")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
