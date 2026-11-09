import CryptoKit
import XCTest
@testable import NotiBridgeCore

final class MemoryStore: PairedKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func key(for deviceId: String) -> SymmetricKey? { keys[deviceId] }
    func save(deviceId: String, name: String, key: SymmetricKey) { keys[deviceId] = key }
    func remove(deviceId: String) { keys.removeValue(forKey: deviceId) }
}

/// 用 Swift 模拟手机端协议流程（这是协议单元测试，不是真机测试）。
final class SessionMachineTests: XCTestCase {
    private func sent(_ outs: [SessionMachine.Output]) -> Envelope? {
        for o in outs { if case let .send(s) = o { return Envelope.parse(s) } }
        return nil
    }

    private func pair(store: MemoryStore, window: PairingWindow, pinTyped: String) -> (SymmetricKey, [SessionMachine.Output]) {
        let m = SessionMachine(store: store, window: window, macId: "mac", macName: "Mac")
        let phonePriv = Curve25519.KeyAgreement.PrivateKey()
        let phonePub = phonePriv.publicKey.rawRepresentation
        let chal = sent(m.handle(Envelope(t: "pair_req", deviceId: "dev1", deviceName: "Phone",
                                          pub: phonePub.base64EncodedString()).json()))!
        XCTAssertEqual(chal.t, "pair_chal")
        let macPub = Data(base64Encoded: chal.pub!)!
        let key = try! BridgeCrypto.derivePairKey(privateKey: phonePriv, peerPub: macPub,
                                                  phonePub: phonePub, macPub: macPub, pin: pinTyped)
        let outs = m.handle(Envelope(t: "pair_confirm", box: try! BridgeCrypto.seal(key, "pair-confirm-phone")).json())
        return (key, outs)
    }

    func testPairAuthNotifyAndReplay() throws {
        let store = MemoryStore()
        let window = PairingWindow()
        window.open()
        let (key, outs) = pair(store: store, window: window, pinTyped: window.activePin()!)
        let ok = sent(outs)!
        XCTAssertEqual(ok.t, "pair_ok")
        XCTAssertEqual(try BridgeCrypto.open(key, ok.box!), "pair-confirm-mac")
        XCTAssertNotNil(store.keys["dev1"])
        XCTAssertNil(window.activePin(), "配对成功后 PIN 必须作废")

        let m = SessionMachine(store: store, window: window, macId: "mac", macName: "Mac")
        let phoneNonce = BridgeCrypto.randomBytes(16).base64EncodedString()
        let chal = sent(m.handle(Envelope(t: "hello", deviceId: "dev1", nonce: phoneNonce).json()))!
        XCTAssertEqual(chal.t, "challenge")
        let macNonce = chal.nonce!
        let authOk = sent(m.handle(Envelope(t: "auth", box: try BridgeCrypto.seal(key, "auth|\(phoneNonce)|\(macNonce)")).json()))!
        XCTAssertEqual(authOk.t, "auth_ok")
        XCTAssertEqual(try BridgeCrypto.open(key, authOk.box!), "ok|\(macNonce)|\(phoneNonce)")
        XCTAssertTrue(m.isAuthenticated)

        let inner = Inner(kind: "notify", sid: macNonce, seq: 1, id: "h1", bundleName: "com.a", appName: "A",
                          title: "t", text: "x", time: 1_700_000_000_000, test: true)
        let frame = Envelope(t: "msg", box: try BridgeCrypto.seal(key, inner.json())).json()
        let r = m.handle(frame)
        guard case let .notify(n, seq) = r.first else { return XCTFail("expected notify, got \(r)") }
        XCTAssertEqual(n.id, "h1")
        XCTAssertTrue(n.isTest)
        XCTAssertEqual(seq, 1)

        let otp = Inner(kind: "otp", sid: macNonce, seq: 2, id: "h2", bundleName: "com.ohos.mms", appName: "信息",
                        code: "123456")
        let r2 = m.handle(Envelope(t: "msg", box: try BridgeCrypto.seal(key, otp.json())).json())
        guard case let .otp(o, seq2) = r2.first else { return XCTFail("expected otp, got \(r2)") }
        XCTAssertEqual(o.code, "123456")
        XCTAssertEqual(seq2, 2)

        let stMsg = Inner(kind: "settings", sid: macNonce, seq: 3, paused: true, blockSensitive: false, copyOtp: true,
                          updatedAt: 2000)
        let r3 = m.handle(Envelope(t: "msg", box: try BridgeCrypto.seal(key, stMsg.json())).json())
        guard case let .settings(st, seq3) = r3.first else { return XCTFail("expected settings, got \(r3)") }
        XCTAssertEqual(st, SharedSettings(paused: true, blockSensitive: false, copyOtp: true, updatedAt: 2000))
        XCTAssertEqual(seq3, 3)
        let back = Envelope.parse(m.settingsFrame(st, seq: 3)!)!
        XCTAssertEqual(Inner.parse(try BridgeCrypto.open(key, back.box!))?.paused, true)

        // 重放同一帧必须被拒绝并断开
        let replay = m.handle(frame)
        XCTAssertTrue(replay.contains(.close("replay")))
    }

    func testWrongPinRejectedAndWindowClosesAfterThreeFailures() {
        let store = MemoryStore()
        let window = PairingWindow()
        window.open()
        let real = window.activePin()!
        let wrong = real == "000000" ? "111111" : "000000"
        for i in 1...3 {
            let (_, outs) = pair(store: store, window: window, pinTyped: wrong)
            XCTAssertEqual(sent(outs)?.code, "bad_pin")
            XCTAssertEqual(window.failures, i)
        }
        XCTAssertNil(window.activePin())
        XCTAssertTrue(store.keys.isEmpty)
    }

    func testUnknownDeviceRejected() {
        let m = SessionMachine(store: MemoryStore(), window: PairingWindow(), macId: "mac", macName: "Mac")
        let outs = m.handle(Envelope(t: "hello", deviceId: "x", nonce: BridgeCrypto.randomBytes(16).base64EncodedString()).json())
        XCTAssertEqual(sent(outs)?.code, "unknown_device")
        // v1.2：带上电脑 ID，手机据此确认是这台电脑取消了配对
        XCTAssertEqual(sent(outs)?.macId, "mac")
        XCTAssertTrue(outs.contains(.close("unknown_device")))
    }

    /// 登录一台已配对的手机，返回状态机、密钥和会话 sid
    private func authenticated(store: MemoryStore) throws -> (SessionMachine, SymmetricKey, String) {
        let key = SymmetricKey(size: .bits256)
        store.keys["dev1"] = key
        let m = SessionMachine(store: store, window: PairingWindow(), macId: "mac", macName: "Mac")
        let phoneNonce = BridgeCrypto.randomBytes(16).base64EncodedString()
        let chal = sent(m.handle(Envelope(t: "hello", deviceId: "dev1", nonce: phoneNonce).json()))!
        let sid = chal.nonce!
        _ = m.handle(Envelope(t: "auth", box: try BridgeCrypto.seal(key, "auth|\(phoneNonce)|\(sid)")).json())
        XCTAssertTrue(m.isAuthenticated)
        return (m, key, sid)
    }

    func testPhoneUnpairRemovesKeyAcksAndCloses() throws {
        let store = MemoryStore()
        let (m, key, sid) = try authenticated(store: store)
        let inner = Inner(kind: "unpair", sid: sid, seq: 1)
        let outs = m.handle(Envelope(t: "msg", box: try BridgeCrypto.seal(key, inner.json())).json())
        XCTAssertTrue(outs.contains(.unpaired(deviceId: "dev1")))
        XCTAssertTrue(outs.contains(.close("unpaired")))
        XCTAssertNil(store.keys["dev1"], "取消配对后必须删除密钥")
        let ack = Inner.parse(try BridgeCrypto.open(key, sent(outs)!.box!))!
        XCTAssertEqual(ack.kind, "ack")
        XCTAssertEqual(ack.result, "unpaired")
        XCTAssertEqual(ack.seq, 1)
        XCTAssertFalse(m.isAuthenticated)

        // 之后同一台手机再连接：unknown_device
        let m2 = SessionMachine(store: store, window: PairingWindow(), macId: "mac", macName: "Mac")
        let r = m2.handle(Envelope(t: "hello", deviceId: "dev1", nonce: BridgeCrypto.randomBytes(16).base64EncodedString()).json())
        XCTAssertEqual(sent(r)?.code, "unknown_device")
    }

    func testUnpairReplayRejected() throws {
        let store = MemoryStore()
        let (m, key, sid) = try authenticated(store: store)
        let wrongSid = Inner(kind: "unpair", sid: "other", seq: 1)
        let outs = m.handle(Envelope(t: "msg", box: try BridgeCrypto.seal(key, wrongSid.json())).json())
        XCTAssertTrue(outs.contains(.close("replay")))
        XCTAssertNotNil(store.keys["dev1"], "会话不符的 unpair 不能删除密钥")
        _ = sid
    }

    func testComputerUnpairFrame() throws {
        let store = MemoryStore()
        let unauth = SessionMachine(store: store, window: PairingWindow(), macId: "mac", macName: "Mac")
        XCTAssertNil(unauth.unpairFrame(), "未认证时不能发 unpair")
        let (m, key, sid) = try authenticated(store: store)
        let env = Envelope.parse(m.unpairFrame()!)!
        XCTAssertEqual(env.t, "msg")
        let inner = Inner.parse(try BridgeCrypto.open(key, env.box!))!
        XCTAssertEqual(inner.kind, "unpair")
        XCTAssertEqual(inner.sid, sid)
        XCTAssertGreaterThan(inner.seq, 0)
    }

    func testPairingClosedWithoutPin() {
        let m = SessionMachine(store: MemoryStore(), window: PairingWindow(), macId: "mac", macName: "Mac")
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(sent(m.handle(Envelope(t: "pair_req", deviceId: "d", pub: pub).json()))?.code, "pairing_closed")
    }

    func testSettingsMergeLaterWins() {
        let local = SharedSettings(paused: false, blockSensitive: true, copyOtp: true, updatedAt: 100)
        let newer = SharedSettings(paused: true, blockSensitive: false, copyOtp: false, updatedAt: 200)
        let older = SharedSettings(paused: true, blockSensitive: false, copyOtp: false, updatedAt: 50)
        XCTAssertEqual(local.merged(with: newer), newer)
        XCTAssertEqual(local.merged(with: older), local)
    }

    func testFilterAndDedup() {
        var f = SyncFilter()
        XCTAssertEqual(f.decide(bundleName: "com.sms", title: "短信", text: "您的验证码是 123456"), .block("疑似敏感内容"))
        XCTAssertEqual(f.decide(bundleName: "com.sms", title: "张三", text: "晚上吃饭"), .allow)
        f.blacklist = ["com.sms"]
        XCTAssertEqual(f.decide(bundleName: "com.sms", title: "a", text: "b"), .block("黑名单应用"))
        f.mode = .whitelistOnly
        XCTAssertEqual(f.decide(bundleName: "com.qq", title: "a", text: "b"), .block("不在白名单"))

        let d = NotificationDeduper()
        let n = MirroredNotification(id: "1", bundleName: "b", appName: "a", title: "t", text: "x", time: Date(), isTest: false)
        XCTAssertEqual(d.check(n), .new)
        XCTAssertEqual(d.check(n), .duplicate)
        var n2 = n
        n2.text = "y"
        XCTAssertEqual(d.check(n2), .updated)
    }
}
