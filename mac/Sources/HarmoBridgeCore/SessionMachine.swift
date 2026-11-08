import CryptoKit
import Foundation

/// 已配对设备的密钥存储（App 中由钥匙串实现，测试中用内存实现）。
public protocol PairedKeyStore: AnyObject {
    func key(for deviceId: String) -> SymmetricKey?
    func save(deviceId: String, name: String, key: SymmetricKey)
}

/// Mac 端当前开放的配对窗口：一次性 PIN，限时、限次。
public final class PairingWindow {
    public private(set) var pin: String?
    public private(set) var expiresAt: Date?
    public private(set) var failures = 0
    public let maxFailures = 3
    public let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 120) {
        self.lifetime = lifetime
    }

    public func open(now: Date = Date()) {
        pin = BridgeCrypto.randomPin()
        expiresAt = now.addingTimeInterval(lifetime)
        failures = 0
    }

    public func close() {
        pin = nil
        expiresAt = nil
    }

    public func activePin(now: Date = Date()) -> String? {
        guard let pin, let expiresAt, now < expiresAt else { return nil }
        return pin
    }

    /// PIN 错误一次；达到上限时作废。
    public func recordFailure() {
        failures += 1
        if failures >= maxFailures {
            close()
        }
    }
}

/// 单条 WebSocket 连接的协议状态机。与网络层解耦：输入一帧文本，输出要执行的动作。
public final class SessionMachine {
    public enum Output: Equatable {
        case send(String)
        case close(String)
        case paired(deviceId: String, name: String, sas: String)
        case pairingStarted(sas: String)
        case authenticated(deviceId: String)
        case notify(MirroredNotification, seq: Int)
        case cancel([String], seq: Int)
        case otp(OtpCode, seq: Int)
        case ping(seq: Int)
        case log(String)
    }

    private enum State {
        case awaitingFirst
        case pairing(priv: Curve25519.KeyAgreement.PrivateKey, phonePub: Data, macPub: Data,
                     deviceId: String, name: String, sas: String)
        case awaitingAuth(deviceId: String, key: SymmetricKey, phoneNonce: String, macNonce: String)
        case authenticated(deviceId: String, key: SymmetricKey, sid: String, lastSeq: Int)
        case closed
    }

    private var state: State = .awaitingFirst
    private let store: PairedKeyStore
    private let window: PairingWindow
    private let macId: String
    private let macName: String

    public private(set) var deviceId: String?

    public init(store: PairedKeyStore, window: PairingWindow, macId: String, macName: String) {
        self.store = store
        self.window = window
        self.macId = macId
        self.macName = macName
    }

    public var isAuthenticated: Bool {
        if case .authenticated = state { return true }
        return false
    }

    public func handle(_ text: String, now: Date = Date()) -> [Output] {
        guard let env = Envelope.parse(text) else {
            return fail("bad_frame", log: "收到无法解析的帧")
        }
        switch state {
        case .awaitingFirst:
            switch env.t {
            case "pair_req": return startPairing(env, now: now)
            case "hello": return startAuth(env)
            default: return fail("unexpected", log: "首帧类型非法：\(env.t)")
            }
        case let .pairing(priv, phonePub, macPub, devId, name, sas):
            guard env.t == "pair_confirm", let box = env.box else {
                return fail("unexpected", log: "配对阶段收到非法帧：\(env.t)")
            }
            guard let pin = window.activePin(now: now) else {
                return fail("pairing_closed", log: "配对窗口已关闭或 PIN 已过期")
            }
            guard let key = try? BridgeCrypto.derivePairKey(privateKey: priv, peerPub: phonePub,
                                                             phonePub: phonePub, macPub: macPub, pin: pin),
                  let plain = try? BridgeCrypto.open(key, box), plain == "pair-confirm-phone" else {
                window.recordFailure()
                return fail("bad_pin", log: "配对失败：PIN 错误（第 \(window.failures) 次）")
            }
            store.save(deviceId: devId, name: name, key: key)
            window.close()
            state = .closed
            deviceId = devId
            let ok = Envelope(t: "pair_ok", box: (try? BridgeCrypto.seal(key, "pair-confirm-mac")) ?? "")
            return [.send(ok.json()), .paired(deviceId: devId, name: name, sas: sas), .close("paired")]
        case let .awaitingAuth(devId, key, phoneNonce, macNonce):
            guard env.t == "auth", let box = env.box,
                  let plain = try? BridgeCrypto.open(key, box),
                  plain == "auth|\(phoneNonce)|\(macNonce)" else {
                return fail("auth_failed", log: "认证失败：设备 \(devId)")
            }
            state = .authenticated(deviceId: devId, key: key, sid: macNonce, lastSeq: 0)
            let ok = Envelope(t: "auth_ok", box: (try? BridgeCrypto.seal(key, "ok|\(macNonce)|\(phoneNonce)")) ?? "")
            return [.send(ok.json()), .authenticated(deviceId: devId)]
        case let .authenticated(devId, key, sid, lastSeq):
            guard env.t == "msg", let box = env.box,
                  let plain = try? BridgeCrypto.open(key, box), let inner = Inner.parse(plain) else {
                return fail("bad_msg", log: "无法解密的业务消息")
            }
            guard inner.sid == sid, inner.seq > lastSeq else {
                return fail("replay", log: "拒绝重放或乱序消息 seq=\(inner.seq)")
            }
            state = .authenticated(deviceId: devId, key: key, sid: sid, lastSeq: inner.seq)
            return dispatch(inner, now: now)
        case .closed:
            return []
        }
    }

    /// 给手机回 ack（认证后才有效）。
    public func ack(seq: Int, result: String) -> String? {
        guard case let .authenticated(_, key, sid, _) = state else { return nil }
        let inner = Inner(kind: "ack", sid: sid, seq: seq, result: result)
        guard let box = try? BridgeCrypto.seal(key, inner.json()) else { return nil }
        return Envelope(t: "msg", box: box).json()
    }

    private func dispatch(_ inner: Inner, now: Date) -> [Output] {
        switch inner.kind {
        case "notify":
            guard let id = inner.id, !id.isEmpty else { return [.log("notify 缺少 id，已忽略")] }
            let n = MirroredNotification(
                id: id,
                bundleName: inner.bundleName ?? "",
                appName: inner.appName ?? (inner.bundleName ?? ""),
                title: inner.title ?? "",
                text: inner.text ?? "",
                time: inner.time.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now,
                isTest: inner.test ?? false
            )
            return [.notify(n, seq: inner.seq)]
        case "cancel":
            return [.cancel(inner.ids ?? [], seq: inner.seq)]
        case "otp":
            guard let code = inner.code, (4...8).contains(code.count), code.allSatisfy(\.isNumber) else {
                return [.log("验证码消息格式不对，已忽略")]
            }
            let bundle = inner.bundleName ?? ""
            return [.otp(OtpCode(id: inner.id ?? "", bundleName: bundle, appName: inner.appName ?? bundle,
                                 code: code), seq: inner.seq)]
        case "ping":
            return [.ping(seq: inner.seq)]
        default:
            // call.* 预留给 ESP32 通话模块，通知模块不处理
            return [.log("忽略未知消息类型：\(inner.kind)")]
        }
    }

    private func startPairing(_ env: Envelope, now: Date) -> [Output] {
        guard window.activePin(now: now) != nil else {
            return fail("pairing_closed", log: "收到配对请求，但 Mac 未开启配对")
        }
        guard let devId = env.deviceId, !devId.isEmpty, let pubB64 = env.pub,
              let phonePub = Data(base64Encoded: pubB64), phonePub.count == 32 else {
            return fail("bad_pair_req", log: "配对请求字段不完整")
        }
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let macPub = priv.publicKey.rawRepresentation
        let sas = BridgeCrypto.sas(phonePub: phonePub, macPub: macPub)
        let name = env.deviceName ?? "未知设备"
        state = .pairing(priv: priv, phonePub: phonePub, macPub: macPub, deviceId: devId, name: name, sas: sas)
        deviceId = devId
        let chal = Envelope(t: "pair_chal", macId: macId, macName: macName, pub: macPub.base64EncodedString())
        return [.send(chal.json()), .pairingStarted(sas: sas)]
    }

    private func startAuth(_ env: Envelope) -> [Output] {
        guard let devId = env.deviceId, let phoneNonce = env.nonce,
              let raw = Data(base64Encoded: phoneNonce), raw.count == 16 else {
            return fail("bad_hello", log: "hello 字段不完整")
        }
        guard let key = store.key(for: devId) else {
            return fail("unknown_device", log: "未配对设备尝试连接：\(devId)")
        }
        let macNonce = BridgeCrypto.randomBytes(16).base64EncodedString()
        state = .awaitingAuth(deviceId: devId, key: key, phoneNonce: phoneNonce, macNonce: macNonce)
        deviceId = devId
        return [.send(Envelope(t: "challenge", nonce: macNonce).json())]
    }

    private func fail(_ code: String, log: String) -> [Output] {
        state = .closed
        return [.log(log), .send(Envelope(t: "error", code: code).json()), .close(code)]
    }
}
