import XCTest
@testable import NotiBridgeCore

final class ConnectionGuardTests: XCTestCase {
    func testConnectionCapAndRelease() {
        let g = ConnectionGuard()
        let t = Date()
        for i in 0..<16 { XCTAssertEqual(g.admit(ip: "10.0.0.\(i)", now: t), .allow) }
        XCTAssertEqual(g.admit(ip: "10.0.0.99", now: t), .tooManyConnections)
        g.connectionClosed()
        XCTAssertEqual(g.admit(ip: "10.0.0.99", now: t), .allow)
    }

    func testPerIpRateWindow() {
        let g = ConnectionGuard()
        let t = Date()
        for _ in 0..<10 {
            XCTAssertEqual(g.admit(ip: "1.1.1.1", now: t), .allow)
            g.connectionClosed()
        }
        XCTAssertEqual(g.admit(ip: "1.1.1.1", now: t.addingTimeInterval(30)), .rateLimited)
        XCTAssertEqual(g.admit(ip: "2.2.2.2", now: t.addingTimeInterval(30)), .allow, "别的 IP 不受影响")
        XCTAssertEqual(g.admit(ip: "1.1.1.1", now: t.addingTimeInterval(61)), .allow, "一分钟后恢复")
    }

    func testExponentialLockout() {
        let g = ConnectionGuard()
        let t = Date()
        g.recordFailure(ip: "x", now: t)
        g.recordFailure(ip: "x", now: t)
        XCTAssertEqual(g.admit(ip: "x", now: t), .allow)
        g.connectionClosed()
        g.recordFailure(ip: "x", now: t) // 第 3 次：封 30 秒
        XCTAssertEqual(g.admit(ip: "x", now: t.addingTimeInterval(29)), .lockedOut(until: t.addingTimeInterval(30)))
        XCTAssertEqual(g.admit(ip: "x", now: t.addingTimeInterval(31)), .allow)
        g.connectionClosed()
        g.recordFailure(ip: "x", now: t.addingTimeInterval(31)) // 第 4 次：60 秒
        XCTAssertEqual(g.admit(ip: "x", now: t.addingTimeInterval(90)), .lockedOut(until: t.addingTimeInterval(91)))
        for _ in 0..<20 { g.recordFailure(ip: "x", now: t) }
        if case let .lockedOut(until) = g.admit(ip: "x", now: t) {
            XCTAssertEqual(until.timeIntervalSince(t), 3600, accuracy: 0.001, "最长封 1 小时")
        } else { XCTFail("应被封禁") }
        g.recordSuccess(ip: "x")
        XCTAssertEqual(g.admit(ip: "x", now: t), .allow, "认证成功后清零")
    }

    func testFrameLimitsAndDeadlines() {
        let g = ConnectionGuard()
        XCTAssertEqual(g.maxFrame(authenticated: false), 16 * 1024)
        XCTAssertEqual(g.maxFrame(authenticated: true), 256 * 1024)
        XCTAssertEqual(g.deadline(isPairing: false), 10)
        XCTAssertEqual(g.deadline(isPairing: true), 90)
    }
}
