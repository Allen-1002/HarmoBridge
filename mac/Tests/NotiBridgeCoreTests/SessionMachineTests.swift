import CryptoKit
import XCTest
@testable import NotiBridgeCore

/// 协议 v2 状态机测试（用 Swift 模拟手机端；这是单元测试，不是真机测试）。
final class SessionMachineTests: XCTestCase {
    private func sent(_ outs: [SessionMachine.Output]) -> Envelope? {
        for o in outs { if case let .send(s) = o { return Envelope.parse(s) } }
        return nil
    }

    private func machine(_ store: MemoryStore, _ window: PairingWindow) -> SessionMachine {
        SessionMachine(store: store, window: window, macId: "mac-1", macName: "Mac")
    }

    /// 完整配对一次，返回手机模拟器和最后一步的输出
    @discardableResult
    private func pair(_ phone: PhoneSim, store: MemoryStore, window: PairingWindow, pinTyped: String)
        throws -> [SessionMachine.Output] {
        let m = machine(store, window)
        let chal = sent(m.handle(phone.pairReq()))!
        XCTAssertEqual(chal.t, "pair_chal")
        XCTAssertEqual(chal.v, 2)
        let started = m.handle(try phone.pairKey(chal, pin: pinTyped))
        guard case let .pairingStarted(sas) = started.first else { XCTFail("no SAS: \(started)"); return [] }
        XCTAssertEqual(sas, phone.keys?.sas, "两端 SAS 必须一致")
        return m.handle(phone.pairConfirm())
    }

    private func authenticate(_ phone: PhoneSim, _ m: SessionMachine) throws {
        let chal = sent(m.handle(phone.hello()))!
        XCTAssertEqual(chal.t, "challenge")
        XCTAssertEqual(chal.v, 2)
        let ok = sent(m.handle(try phone.auth(chal)))!
        XCTAssertTrue(phone.checkAuthOk(ok))
        XCTAssertTrue(m.isAuthenticated)
    }

    func testPairAuthNotifyAndReplay() throws {
        let store = MemoryStore()
        let window = PairingWindow()
        window.open()
        let phone = PhoneSim(deviceId: "dev1")
        let outs = try pair(phone, store: store, window: window, pinTyped: window.activePin()!)
        XCTAssertTrue(phone.acceptPairOk(sent(outs)!))
        XCTAssertTrue(outs.contains { if case .paired(deviceId: "dev1", name: "Phone", sas: _) = $0 { return true }; return false })
        XCTAssertEqual(store.keys["dev1"]?.withUnsafeBytes { Data($0) }, phone.key?.withUnsafeBytes { Data($0) })
        XCTAssertNil(window.activePin(), "配对成功后 PIN 必须作废")

        let m = machine(store, window)
        try authenticate(phone, m)
        let frame = try phone.notify("h1")
        let r = m.handle(frame)
        guard case let .notify(n, seq) = r.first else { return XCTFail("expected notify, got \(r)") }
        XCTAssertEqual(n.id, "h1")
        XCTAssertEqual(seq, 1)

        phone.seq += 1
        let otp = Inner(kind: "otp", sid: phone.sid, seq: phone.seq, id: "h2", bundleName: "com.ohos.mms", appName: "信息",
                        code: "123456")
        guard case let .otp(o, _) = m.handle(try phone.msg(otp)).first else { return XCTFail("expected otp") }
        XCTAssertEqual(o.code, "123456")
        phone.seq += 1
        let bad = Inner(kind: "otp", sid: phone.sid, seq: phone.seq, code: "１２３４") // 全角数字不接受
        guard case .log = m.handle(try phone.msg(bad)).first else { return XCTFail("全角验证码应被忽略") }

        phone.seq += 1
        let st = Inner(kind: "settings", sid: phone.sid, seq: phone.seq, paused: true, blockSensitive: false,
                       copyOtp: true, updatedAt: 2000)
        guard case let .settings(v, s3) = m.handle(try phone.msg(st)).first else { return XCTFail("expected settings") }
        XCTAssertEqual(v, SharedSettings(paused: true, blockSensitive: false, copyOtp: true, updatedAt: 2000))
        let back = phone.receive(Envelope.parse(m.settingsFrame(v, seq: s3)!)!)
        XCTAssertEqual(back?.paused, true)
        XCTAssertEqual(back?.seq, s3)

        // 重放同一帧必须被拒绝并断开
        XCTAssertTrue(m.handle(frame).contains(.close("replay")))
    }

    func testComputerFramesCarryIncreasingCseqAndPhoneRejectsReplay() throws {
        let store = MemoryStore()
        let (phone, m) = try paired(store)
        let a1 = Envelope.parse(m.ack(seq: 1, result: "shown")!)!
        let a2 = Envelope.parse(m.settingsFrame(SharedSettings(paused: false, blockSensitive: true, copyOtp: true, updatedAt: 1))!)!
        let a3 = Envelope.parse(m.unpairFrame()!)!
        XCTAssertEqual(phone.receive(a1)?.cseq, 1)
        XCTAssertEqual(phone.receive(a2)?.cseq, 2)
        XCTAssertNil(phone.receive(a1), "重放旧的 ack 必须被手机拒绝")
        XCTAssertNil(phone.receive(a2), "重放旧的 settings 必须被手机拒绝")
        XCTAssertEqual(phone.receive(a3)?.kind, "unpair")
        XCTAssertNil(phone.receive(a3), "unpair 不能被重复执行")
        // 电脑消息反射回电脑：方向 AAD 不同，解不开
        XCTAssertTrue(m.handle(a2.json()).contains(.close("bad_msg")))
    }

    private func paired(_ store: MemoryStore, id: String = "dev1") throws -> (PhoneSim, SessionMachine) {
        let window = PairingWindow()
        window.open()
        let phone = PhoneSim(deviceId: id)
        let outs = try pair(phone, store: store, window: window, pinTyped: window.activePin()!)
        XCTAssertTrue(phone.acceptPairOk(sent(outs)!))
        let m = machine(store, window)
        try authenticate(phone, m)
        return (phone, m)
    }

    func testWrongPinRejectedAndWindowClosesAfterThreeFailures() throws {
        let store = MemoryStore()
        let window = PairingWindow()
        window.open()
        let real = window.activePin()!
        let wrong = real == "000000" ? "111111" : "000000"
        for i in 1...3 {
            let phone = PhoneSim(deviceId: "attacker")
            let outs = try pair(phone, store: store, window: window, pinTyped: wrong)
            XCTAssertEqual(sent(outs)?.code, "bad_pin", "第 \(i) 次")
            XCTAssertEqual(window.failures, i)
        }
        XCTAssertNil(window.activePin(), "3 次失败后 PIN 作废")
        XCTAssertTrue(store.keys.isEmpty)
        // 作废后即使猜中也不行
        let m = machine(store, window)
        XCTAssertEqual(sent(m.handle(PhoneSim(deviceId: "x").pairReq()))?.code, "pairing_closed")
    }

    func testForgedConfirmMacRejected() throws {
        let store = MemoryStore()
        let window = PairingWindow()
        window.open()
        let phone = PhoneSim(deviceId: "d")
        let m = machine(store, window)
        let chal = sent(m.handle(phone.pairReq()))!
        _ = m.handle(try phone.pairKey(chal, pin: window.activePin()!))
        let forged = Envelope(t: "pair_confirm", confirm: BridgeCrypto.randomBytes(32).base64EncodedString()).json()
        XCTAssertEqual(sent(m.handle(forged))?.code, "bad_pin")
        XCTAssertEqual(window.failures, 1)
        XCTAssertTrue(store.keys.isEmpty)
    }

    func testReplayedPairMessagesFromAnotherSessionRejected() throws {
        let store = MemoryStore()
        let window = PairingWindow()
        window.open()
        let pin = window.activePin()!
        // 第一次配对的消息被录下来
        let phone = PhoneSim(deviceId: "d")
        let m1 = machine(store, window)
        let chal1 = sent(m1.handle(phone.pairReq()))!
        let keyFrame = try phone.pairKey(chal1, pin: pin)
        let confirmFrame = phone.pairConfirm()
        // 攻击者在新连接上重放 pair_key / pair_confirm：电脑的 nonce 和 Yb 每次都不同，确认码对不上
        let m2 = machine(store, window)
        let replayReq = Envelope(t: "pair_req", v: 2, deviceId: "d", deviceName: "Phone", platform: "android",
                                 nonce: phone.phoneNonce.base64EncodedString()).json()
        XCTAssertEqual(sent(m2.handle(replayReq))?.t, "pair_chal")
        _ = m2.handle(keyFrame)
        XCTAssertEqual(sent(m2.handle(confirmFrame))?.code, "bad_pin")
        XCTAssertTrue(store.keys.isEmpty)
        // 同一连接里重复发 pair_key：非法
        let m3 = machine(store, window)
        let p3 = PhoneSim(deviceId: "e")
        let chal3 = sent(m3.handle(p3.pairReq()))!
        let k3 = try p3.pairKey(chal3, pin: pin)
        _ = m3.handle(k3)
        XCTAssertEqual(sent(m3.handle(k3))?.code, "unexpected")
    }

    func testLowOrderPointAbortsPairing() throws {
        let vectors = try loadVectors()["cpaceOfficial"] as! [String: Any]
        let bad = (vectors["lowOrder"] as! [[String: Any]]).filter { $0["mustAbort"] as! Bool }
        XCTAssertFalse(bad.isEmpty)
        let store = MemoryStore()
        for item in bad {
            let window = PairingWindow()
            window.open()
            let m = machine(store, window)
            _ = m.handle(PhoneSim(deviceId: "d").pairReq())
            let frame = Envelope(t: "pair_key", pub: hexData(item["u"] as! String).base64EncodedString()).json()
            let outs = m.handle(frame)
            XCTAssertEqual(sent(outs)?.code, "bad_point", "\(item["u"]!)")
            XCTAssertEqual(window.failures, 1, "低阶点计一次失败")
        }
        XCTAssertTrue(store.keys.isEmpty)
    }

    func testPhoneRejectsComputerWithWrongConfirm() throws {
        // 冒充电脑的一方不知道 PIN：手机核对 confirmComputer 失败，不保存密钥
        let window = PairingWindow()
        window.open()
        let phone = PhoneSim(deviceId: "d")
        let m = machine(MemoryStore(), window)
        let chal = sent(m.handle(phone.pairReq()))!
        _ = try phone.pairKey(chal, pin: "999999" == window.activePin()! ? "888888" : "999999")
        XCTAssertFalse(phone.acceptPairOk(Envelope(t: "pair_ok", confirm: BridgeCrypto.randomBytes(32).base64EncodedString())))
        XCTAssertNil(phone.key)
    }

    func testPinExpiredBetweenChallengeAndConfirm() throws {
        let window = PairingWindow(lifetime: 120)
        let t0 = Date()
        window.open(now: t0)
        let phone = PhoneSim(deviceId: "d")
        let store = MemoryStore()
        let m = machine(store, window)
        let chal = sent(m.handle(phone.pairReq(), now: t0))!
        _ = m.handle(try phone.pairKey(chal, pin: window.activePin(now: t0)!), now: t0)
        XCTAssertEqual(sent(m.handle(phone.pairConfirm(), now: t0.addingTimeInterval(121)))?.code, "pairing_closed")
        XCTAssertTrue(store.keys.isEmpty)
    }

    func testOldVersionPeersGetUpgradeRequired() {
        let window = PairingWindow()
        window.open()
        for frame in [PhoneSim(deviceId: "d").pairReq(version: nil), PhoneSim(deviceId: "d").hello(version: nil),
                      PhoneSim(deviceId: "d").hello(version: 1)] {
            let outs = machine(MemoryStore(), window).handle(frame)
            XCTAssertEqual(sent(outs)?.code, "upgrade_required")
            XCTAssertTrue(outs.contains(.peerOutdated))
            XCTAssertTrue(outs.contains(.close("upgrade_required")))
        }
    }

    func testIllegalMessages() throws {
        let store = MemoryStore()
        let window = PairingWindow()
        XCTAssertTrue(machine(store, window).handle("not json").contains(.close("bad_frame")))
        XCTAssertTrue(machine(store, window).handle("{\"t\":\"msg\",\"box\":\"AAAA\"}").contains(.close("unexpected")))
        XCTAssertTrue(machine(store, window).handle("{\"x\":1}").contains(.close("bad_frame")))
        XCTAssertEqual(sent(machine(store, window).handle(Envelope(t: "hello", v: 2, deviceId: "d", nonce: "short").json()))?.code,
                       "bad_hello")
        window.open()
        XCTAssertEqual(sent(machine(store, window).handle(Envelope(t: "pair_req", v: 2, deviceId: "d", nonce: "AAAA").json()))?.code,
                       "bad_pair_req")
        let longName = String(repeating: "长", count: 65)
        XCTAssertEqual(sent(machine(store, window).handle(Envelope(t: "pair_req", v: 2, deviceId: "d", deviceName: longName,
                                                                     nonce: BridgeCrypto.randomBytes(16).base64EncodedString()).json()))?.code,
                       "bad_pair_req")

        // 认证用错方向的 AAD：失败
        let (phone, _) = try paired(store)
        let m = machine(store, window)
        let chal = sent(m.handle(phone.hello()))!
        _ = try phone.auth(chal)
        let wrongDir = Envelope(t: "auth", box: try BridgeCrypto.seal(phone.key!, "auth|\(phone.authNonce)|\(phone.sid)", .toPhone))
        XCTAssertTrue(m.handle(wrongDir.json()).contains(.close("auth_failed")))

        // 认证后：sid 不符 / seq 不递增 / 无法解密
        let (p2, m2) = try paired(store, id: "dev2")
        XCTAssertTrue(m2.handle(try p2.msg(Inner(kind: "ping", sid: "other", seq: 1))).contains(.close("replay")))
        let (p3, m3) = try paired(store, id: "dev3")
        _ = m3.handle(try p3.msg(Inner(kind: "ping", sid: p3.sid, seq: 5)))
        XCTAssertTrue(m3.handle(try p3.msg(Inner(kind: "ping", sid: p3.sid, seq: 5))).contains(.close("replay")))
        let (_, m4) = try paired(store, id: "dev4")
        XCTAssertTrue(m4.handle(Envelope(t: "msg", box: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").json()).contains(.close("bad_msg")))
        // 关闭之后不再处理任何帧
        XCTAssertTrue(m4.handle(try p2.msg(Inner(kind: "ping", sid: "x", seq: 9))).isEmpty)
    }

    func testUnknownDeviceDoesNotLeakComputerId() {
        let m = SessionMachine(store: MemoryStore(), window: PairingWindow(), macId: "mac", macName: "Mac")
        let outs = m.handle(PhoneSim(deviceId: "x").hello())
        XCTAssertEqual(sent(outs)?.code, "unknown_device")
        XCTAssertNil(sent(outs)?.macId)
        XCTAssertTrue(outs.contains(.close("unknown_device")))
    }

    func testPhoneUnpairRemovesKeyAcksAndCloses() throws {
        let store = MemoryStore()
        let (phone, m) = try paired(store)
        let outs = m.handle(try phone.msg(Inner(kind: "unpair", sid: phone.sid, seq: 1)))
        XCTAssertTrue(outs.contains(.unpaired(deviceId: "dev1")))
        XCTAssertTrue(outs.contains(.close("unpaired")))
        XCTAssertNil(store.keys["dev1"], "取消配对后必须删除密钥")
        let ack = phone.receive(sent(outs)!)!
        XCTAssertEqual(ack.kind, "ack")
        XCTAssertEqual(ack.result, "unpaired")
        XCTAssertEqual(ack.seq, 1)
        XCTAssertFalse(m.isAuthenticated)
        let r = machine(store, PairingWindow()).handle(phone.hello())
        XCTAssertEqual(sent(r)?.code, "unknown_device")
    }

    func testUnpairWithWrongSessionRejected() throws {
        let store = MemoryStore()
        let (phone, m) = try paired(store)
        XCTAssertTrue(m.handle(try phone.msg(Inner(kind: "unpair", sid: "other", seq: 1))).contains(.close("replay")))
        XCTAssertNotNil(store.keys["dev1"], "会话不符的 unpair 不能删除密钥")
    }

    func testComputerUnpairFrameOnlyWhenAuthenticated() throws {
        XCTAssertNil(machine(MemoryStore(), PairingWindow()).unpairFrame())
        let (phone, m) = try paired(MemoryStore())
        let inner = phone.receive(Envelope.parse(m.unpairFrame()!)!)!
        XCTAssertEqual(inner.kind, "unpair")
        XCTAssertEqual(inner.sid, phone.sid)
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

    /// 多台手机、大量通知（不经网络）：每台手机的消息都按顺序到达、无一丢失
    func testManyDevicesHighRateThroughStateMachines() throws {
        let store = MemoryStore()
        var pairs: [(PhoneSim, SessionMachine)] = []
        for i in 0..<12 { pairs.append(try paired(store, id: "dev\(i)")) }
        var received = [Int](repeating: 0, count: pairs.count)
        for round in 0..<300 {
            for (idx, (phone, m)) in pairs.enumerated() {
                let outs = m.handle(try phone.notify("n\(round)"))
                guard case let .notify(n, seq) = outs.first else { return XCTFail("dev\(idx) round \(round): \(outs)") }
                XCTAssertEqual(n.id, "n\(round)")
                XCTAssertEqual(seq, round + 1)
                XCTAssertNotNil(phone.receive(Envelope.parse(m.ack(seq: seq, result: "shown")!)!))
                received[idx] += 1
            }
        }
        XCTAssertEqual(received, [Int](repeating: 300, count: pairs.count))
    }
}
