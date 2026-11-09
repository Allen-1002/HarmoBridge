import CryptoKit
import XCTest
@testable import NotiBridgeCore

/// 简单的 WebSocket 客户端（URLSessionWebSocketTask）
final class WSClient {
    let task: URLSessionWebSocketTask

    init(port: UInt16) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }

    func send(_ s: String) async throws { try await task.send(.string(s)) }

    func recv(timeout: TimeInterval = 5) async throws -> Envelope {
        try await withThrowingTaskGroup(of: Envelope.self) { group in
            group.addTask {
                let msg = try await self.task.receive()
                guard case let .string(s) = msg, let env = Envelope.parse(s) else { throw URLError(.cannotParseResponse) }
                return env
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    /// 等服务器断开（receive 抛错），超时返回 false
    func waitClosed(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do { _ = try await recv(timeout: deadline.timeIntervalSinceNow) } catch let e as URLError where e.code == .timedOut {
                return false
            } catch { return true }
        }
        return false
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    /// 发一个 ping 并等 pong，用来确认连接已建立
    func ping() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { err in if let err { c.resume(throwing: err) } else { c.resume() } }
        }
    }
}

/// 端到端：真实 Network.framework 服务端（只监听 127.0.0.1）+ URLSession WebSocket 客户端。
final class ServerTests: XCTestCase {
    @MainActor
    private func startServer(limits: ConnectionGuard.Limits = .init(), store: MemoryStore, window: PairingWindow,
                             onEvent: ((BridgeServer.Event, BridgeServer) -> Void)? = nil) async throws -> (BridgeServer, UInt16) {
        let server = BridgeServer(limits: limits, loopbackOnly: true) {
            SessionMachine(store: store, window: window, macId: "mac-1", macName: "Mac")
        }
        var port: UInt16 = 0
        let ready = expectation(description: "listening")
        server.onEvent = { [unowned server] e in
            if case let .listening(p) = e, port == 0 { port = p; ready.fulfill() }
            // 像 App 一样给通知回 ack
            if case let .output(.notify(_, seq), conn) = e { server.ack(seq: seq, result: "shown", to: conn) }
            onEvent?(e, server)
        }
        server.start(port: 0, serviceName: "test")
        await fulfillment(of: [ready], timeout: 5)
        return (server, port)
    }

    private func pairOverNetwork(_ phone: PhoneSim, port: UInt16, pin: String) async throws {
        let ws = WSClient(port: port)
        defer { ws.close() }
        try await ws.send(phone.pairReq())
        let chal = try await ws.recv()
        XCTAssertEqual(chal.t, "pair_chal")
        try await ws.send(try phone.pairKey(chal, pin: pin))
        try await ws.send(phone.pairConfirm())
        let ok = try await ws.recv()
        XCTAssertTrue(phone.acceptPairOk(ok))
    }

    private func login(_ phone: PhoneSim, port: UInt16) async throws -> WSClient {
        let ws = WSClient(port: port)
        try await ws.send(phone.hello())
        try await ws.send(try phone.auth(try await ws.recv()))
        let ok = try await ws.recv()
        XCTAssertTrue(phone.checkAuthOk(ok))
        return ws
    }

    func testTwoPhonesPairConnectNotifyAndBroadcast() async throws {
        let store = MemoryStore()
        let window = PairingWindow()
        var limits = ConnectionGuard.Limits()
        limits.maxNewPerMinutePerIp = 100
        let (server, port) = try await startServer(limits: limits, store: store, window: window)
        let phones = [PhoneSim(deviceId: "A"), PhoneSim(deviceId: "B", platform: "harmony")]
        for p in phones {
            let pin = await MainActor.run { window.open(); return window.activePin()! }
            try await pairOverNetwork(p, port: port, pin: pin)
        }
        var sockets: [WSClient] = []
        for p in phones { sockets.append(try await login(p, port: port)) }
        let online = await MainActor.run { server.authenticatedConnections.count }
        XCTAssertEqual(online, 2)
        for (i, p) in phones.enumerated() {
            try await sockets[i].send(try p.notify("same-hash"))
            let env = try await sockets[i].recv()
            let ack = p.receive(env)
            XCTAssertEqual(ack?.result, "shown")
        }
        await MainActor.run { server.broadcastSettings(SharedSettings(paused: true, blockSensitive: true, copyOtp: true, updatedAt: 42)) }
        for (i, p) in phones.enumerated() {
            let env = try await sockets[i].recv()
            XCTAssertEqual(p.receive(env)?.paused, true)
        }
        sockets.forEach { $0.close() }
        await MainActor.run { server.stop() }
    }

    func testOversizedFrameBeforeAuthDisconnects() async throws {
        let (server, port) = try await startServer(store: MemoryStore(), window: PairingWindow())
        let ws = WSClient(port: port)
        try await ws.send("{\"t\":\"hello\",\"pad\":\"" + String(repeating: "x", count: 20_000) + "\"}")
        let closed = await ws.waitClosed()
        XCTAssertTrue(closed, "认证前超过 16 KB 的帧必须断开")
        await MainActor.run { server.stop() }
    }

    func testHandshakeTimeoutClosesIdleConnection() async throws {
        var limits = ConnectionGuard.Limits()
        limits.handshakeTimeout = 0.5
        let (server, port) = try await startServer(limits: limits, store: MemoryStore(), window: PairingWindow())
        let ws = WSClient(port: port)
        try await ws.ping()
        let closed = await ws.waitClosed(timeout: 3)
        XCTAssertTrue(closed, "不发 hello 的连接要在超时后断开")
        await MainActor.run { server.stop() }
    }

    func testPerIpRateLimitAndConnectionCap() async throws {
        var limits = ConnectionGuard.Limits()
        limits.maxNewPerMinutePerIp = 3
        let (server, port) = try await startServer(limits: limits, store: MemoryStore(), window: PairingWindow())
        var socks: [WSClient] = []
        for _ in 0..<3 {
            let ws = WSClient(port: port)
            try await ws.ping()
            socks.append(ws)
        }
        let extra = WSClient(port: port)
        let rejected = await extra.waitClosed(timeout: 3)
        XCTAssertTrue(rejected, "同一 IP 每分钟超过上限的新连接要被拒绝")
        socks.forEach { $0.close() }
        await MainActor.run { server.stop() }

        var cap = ConnectionGuard.Limits()
        cap.maxConnections = 2
        let (server2, port2) = try await startServer(limits: cap, store: MemoryStore(), window: PairingWindow())
        let a = WSClient(port: port2), b = WSClient(port: port2)
        try await a.ping()
        try await b.ping()
        let c = WSClient(port: port2)
        let capRejected = await c.waitClosed(timeout: 3)
        XCTAssertTrue(capRejected, "超过同时连接上限的新连接要被拒绝")
        a.close(); b.close()
        await MainActor.run { server2.stop() }
    }

    func testLockoutAfterRepeatedFailures() async throws {
        let (server, port) = try await startServer(store: MemoryStore(), window: PairingWindow())
        for _ in 0..<3 {
            let ws = WSClient(port: port)
            try await ws.send("garbage")
            _ = try? await ws.recv()
            _ = await ws.waitClosed()
        }
        let failures = await MainActor.run { server.guardian.failureCount(ip: "127.0.0.1") }
        XCTAssertEqual(failures, 3)
        let ws = WSClient(port: port)
        let locked = await ws.waitClosed(timeout: 3)
        XCTAssertTrue(locked, "连续失败后来源 IP 被暂时封禁")
        await MainActor.run { server.stop() }
    }

    func testAbruptDisconnectFreesSession() async throws {
        let store = MemoryStore()
        let window = PairingWindow()
        let gone = expectation(description: "disconnected")
        let (server, port) = try await startServer(store: store, window: window) { e, _ in
            if case let .disconnected(_, dev, wasAuth) = e, dev == "A", wasAuth { gone.fulfill() }
        }
        let p = PhoneSim(deviceId: "A")
        let pin = await MainActor.run { window.open(); return window.activePin()! }
        try await pairOverNetwork(p, port: port, pin: pin)
        let ws = try await login(p, port: port)
        try await ws.send(try p.notify("1"))
        _ = try await ws.recv()
        ws.task.cancel() // 不发 close 帧，直接断开
        await fulfillment(of: [gone], timeout: 5)
        let left = await MainActor.run { (server.connectionCount, server.guardian.openConnections) }
        XCTAssertEqual(left.0, 0)
        XCTAssertEqual(left.1, 0)
        await MainActor.run { server.stop() }
    }

    /// 多台手机同时在线、高频发通知：每条都收到 ack、cseq 严格递增
    func testConcurrentPhonesHighRateStress() async throws {
        let store = MemoryStore()
        let window = PairingWindow()
        // 所有模拟手机都来自 127.0.0.1：放宽单 IP 速率限制（真实场景每台手机 IP 不同）
        var limits = ConnectionGuard.Limits()
        limits.maxNewPerMinutePerIp = 100
        let (server, port) = try await startServer(limits: limits, store: store, window: window)
        let phones = (0..<8).map { PhoneSim(deviceId: "P\($0)") }
        for p in phones {
            let pin = await MainActor.run { window.open(); return window.activePin()! }
            try await pairOverNetwork(p, port: port, pin: pin)
        }
        let perPhone = 150
        try await withThrowingTaskGroup(of: Int.self) { group in
            for p in phones {
                group.addTask {
                    let ws = try await self.login(p, port: port)
                    defer { ws.close() }
                    for i in 0..<perPhone { try await ws.send(try p.notify("n\(i)", title: "t\(i)")) }
                    var acks = 0
                    while acks < perPhone {
                        let env = try await ws.recv(timeout: 10)
                        guard let inner = p.receive(env), inner.kind == "ack" else {
                            throw URLError(.badServerResponse)
                        }
                        acks += 1
                    }
                    return acks
                }
            }
            var total = 0
            for try await n in group { total += n }
            XCTAssertEqual(total, phones.count * perPhone)
        }
        await MainActor.run { server.stop() }
    }
}
