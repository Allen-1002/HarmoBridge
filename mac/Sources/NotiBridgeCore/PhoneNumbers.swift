import Foundation

/// 电话号码归一化，用来把来电号码和通讯录匹配。与 Windows 端 PhoneNumbers.cs 一致。
/// 规则：只留数字；去掉国际前缀 00；去掉中国区号 86（+86 138… → 138…）；用最后 11 位比较（短号原样比较）。
public enum PhoneNumbers {
    public static func digits(_ s: String) -> String {
        var d = s.filter(\.isASCII).filter(\.isNumber)
        if d.hasPrefix("00") { d.removeFirst(2) }
        if d.hasPrefix("86") && d.count == 13 { d.removeFirst(2) }
        return d
    }

    /// 匹配用的键；号码太短（例如 10086 这类服务号）就用整个号码
    public static func key(_ s: String) -> String {
        let d = digits(s)
        return d.count > 11 ? String(d.suffix(11)) : d
    }
}

public struct ContactEntry: Identifiable, Hashable {
    public var name: String
    public var number: String
    public var id: String { "\(name)|\(number)" }

    public init(name: String, number: String) {
        self.name = name
        self.number = number
    }
}

/// 通讯录索引：号码 → 名字，以及按名字/号码搜索
public struct ContactIndex {
    public private(set) var entries: [ContactEntry] = []
    private var byKey: [String: String] = [:]

    public init(_ entries: [ContactEntry] = []) {
        for e in entries { add(e) }
    }

    public mutating func add(_ e: ContactEntry) {
        let k = PhoneNumbers.key(e.number)
        guard !k.isEmpty, !e.name.isEmpty else { return }
        entries.append(e)
        if byKey[k] == nil { byKey[k] = e.name }
    }

    public func name(forNumber n: String) -> String? {
        let k = PhoneNumbers.key(n)
        return k.isEmpty ? nil : byKey[k]
    }

    /// 名字包含、或号码数字包含查询内容的联系人
    public func search(_ q: String, limit: Int = 8) -> [ContactEntry] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        let d = PhoneNumbers.digits(t)
        return Array(entries.lazy.filter { e in
            e.name.localizedCaseInsensitiveContains(t) || (!d.isEmpty && PhoneNumbers.digits(e.number).contains(d))
        }.prefix(limit))
    }
}
