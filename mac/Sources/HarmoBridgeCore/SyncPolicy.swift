import Foundation

/// 应用白名单 / 黑名单 + 敏感内容过滤。默认拦截验证码、银行、支付类通知。
public struct SyncFilter: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable {
        case allExceptBlacklist
        case whitelistOnly
    }

    public var mode: Mode = .allExceptBlacklist
    public var whitelist: Set<String> = []
    public var blacklist: Set<String> = []
    public var blockSensitive: Bool = true
    public var sensitiveKeywords: [String] = SyncFilter.defaultKeywords

    public static let defaultKeywords = [
        "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "OTP", "verification code",
        "银行", "信用卡", "余额", "转账", "支付", "付款", "收款",
    ]

    public init() {}

    public enum Decision: Equatable {
        case allow
        case block(String)
    }

    public func decide(bundleName: String, title: String, text: String) -> Decision {
        if blacklist.contains(bundleName) {
            return .block("黑名单应用")
        }
        if mode == .whitelistOnly && !whitelist.contains(bundleName) {
            return .block("不在白名单")
        }
        if blockSensitive {
            let haystack = (title + "\n" + text).lowercased()
            for k in sensitiveKeywords where !k.isEmpty && haystack.contains(k.lowercased()) {
                return .block("疑似敏感内容")
            }
        }
        return .allow
    }
}

/// 以通知 hashCode 去重：同 id 同内容视为重复，同 id 新内容视为更新。
public final class NotificationDeduper {
    public enum Result: Equatable {
        case new
        case updated
        case duplicate
    }

    private var seen: [String: (fingerprint: Int, at: Date)] = [:]
    private let ttl: TimeInterval
    private let capacity: Int

    public init(ttl: TimeInterval = 24 * 3600, capacity: Int = 1000) {
        self.ttl = ttl
        self.capacity = capacity
    }

    public func check(_ n: MirroredNotification, now: Date = Date()) -> Result {
        prune(now)
        var h = Hasher()
        h.combine(n.title)
        h.combine(n.text)
        let fp = h.finalize()
        defer { seen[n.id] = (fp, now) }
        guard let old = seen[n.id] else { return .new }
        return old.fingerprint == fp ? .duplicate : .updated
    }

    public func remove(_ id: String) {
        seen.removeValue(forKey: id)
    }

    private func prune(_ now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value.at) < ttl }
        if seen.count > capacity {
            let keep = seen.sorted { $0.value.at > $1.value.at }.prefix(capacity)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}
