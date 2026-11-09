import Foundation

/// 电脑端 WebSocket 服务的防滥用策略（与 Windows ConnectionGuard.cs 一致，见 docs/protocol.md “电脑端连接限制”）。
/// 纯逻辑、不涉及网络，便于单元测试；调用方负责串行调用（服务端在主队列上调用）。
public final class ConnectionGuard {
    public struct Limits: Equatable {
        public var maxConnections = 16
        public var maxNewPerMinutePerIp = 10
        public var handshakeTimeout: TimeInterval = 10
        public var pairingTimeout: TimeInterval = 90
        public var maxFrameBeforeAuth = 16 * 1024
        public var maxFrameAfterAuth = 256 * 1024
        public var failuresBeforeLockout = 3
        public var baseLockout: TimeInterval = 30
        public var maxLockout: TimeInterval = 3600

        public init() {}
    }

    public enum Verdict: Equatable {
        case allow
        case tooManyConnections
        case rateLimited
        case lockedOut(until: Date)
    }

    private struct IpState {
        var recent: [Date] = []
        var failures = 0
        var lockedUntil: Date?
    }

    public let limits: Limits
    private var ips: [String: IpState] = [:]
    public private(set) var openConnections = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// 新连接到来时调用；返回 .allow 时已计入连接数，关闭时必须调用 connectionClosed()
    public func admit(ip: String, now: Date = Date()) -> Verdict {
        prune(now)
        var st = ips[ip] ?? IpState()
        if let until = st.lockedUntil, until > now { return .lockedOut(until: until) }
        if openConnections >= limits.maxConnections { return .tooManyConnections }
        st.recent = st.recent.filter { now.timeIntervalSince($0) < 60 }
        if st.recent.count >= limits.maxNewPerMinutePerIp {
            ips[ip] = st
            return .rateLimited
        }
        st.recent.append(now)
        ips[ip] = st
        openConnections += 1
        return .allow
    }

    public func connectionClosed() {
        openConnections = max(0, openConnections - 1)
    }

    /// 认证/配对失败：累计到阈值后封禁，之后每次失败封禁时间翻倍
    public func recordFailure(ip: String, now: Date = Date()) {
        var st = ips[ip] ?? IpState()
        st.failures += 1
        if st.failures >= limits.failuresBeforeLockout {
            let exp = Double(st.failures - limits.failuresBeforeLockout)
            let seconds = min(limits.maxLockout, limits.baseLockout * pow(2, exp))
            st.lockedUntil = now.addingTimeInterval(seconds)
        }
        ips[ip] = st
    }

    /// 认证成功：清除失败计数
    public func recordSuccess(ip: String) {
        guard var st = ips[ip] else { return }
        st.failures = 0
        st.lockedUntil = nil
        ips[ip] = st
    }

    /// 当前连接允许的最大帧
    public func maxFrame(authenticated: Bool) -> Int {
        authenticated ? limits.maxFrameAfterAuth : limits.maxFrameBeforeAuth
    }

    /// 未认证连接允许存活的时间（配对中放宽）
    public func deadline(isPairing: Bool) -> TimeInterval {
        isPairing ? limits.pairingTimeout : limits.handshakeTimeout
    }

    public func failureCount(ip: String) -> Int { ips[ip]?.failures ?? 0 }

    private func prune(_ now: Date) {
        // 防止记录无限增长：丢掉 1 小时内没有活动、也没有封禁的 IP
        if ips.count < 1024 { return }
        ips = ips.filter { _, st in
            (st.lockedUntil.map { $0 > now } ?? false) || st.recent.contains { now.timeIntervalSince($0) < 3600 }
        }
    }
}
