import CryptoKit
import XCTest
@testable import HarmoBridgeCore

final class MemoryStore: PairedKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func key(for deviceId: String) -> SymmetricKey? { keys[deviceId] }
    func save(deviceId: String, name: String, key: SymmetricKey) { keys[deviceId] = key }
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
