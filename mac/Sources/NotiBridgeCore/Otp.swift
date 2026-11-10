import Foundation

/// 电脑端直接收到 iPhone 通知（经 ESP32）时，在电脑上提取验证码。
/// 规则与安卓 Filter.kt / 鸿蒙 PhoneFilter.ets 一致：4~8 位数字，离关键词最近（40 个字符内）。
public enum OtpExtractor {
    static let keywords = ["验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "激活码", "otp", "code"]
    static let finance = ["银行", "信用卡", "余额", "转账", "支付", "付款", "收款", "还款", "贷款", "bank", "payment"]
    static let financeAppHints = ["bank", "alipay", "wallet", "pay", "finance", "securities", "stock", "icbc", "ccb",
                                  "cmb", "abchina", "boc"]
    private static let digits = try! NSRegularExpression(pattern: "(?<![0-9])([0-9]{4,8})(?![0-9])")

    public static func extract(title: String, text: String) -> String {
        let content = "\(title) \(text)" as NSString
        let lower = content.lowercased as NSString
        var keyPos: [Int] = []
        for k in keywords {
            var r = lower.range(of: k)
            while r.location != NSNotFound {
                keyPos.append(r.location)
                let next = r.location + r.length
                r = lower.range(of: k, range: NSRange(location: next, length: lower.length - next))
            }
        }
        guard !keyPos.isEmpty else { return "" }
        var best = ""
        var bestDist = Int.max
        for m in digits.matches(in: content as String, range: NSRange(location: 0, length: content.length)) {
            for k in keyPos {
                let d = abs(m.range.location - k)
                if d <= 40 && d < bestDist {
                    bestDist = d
                    best = content.substring(with: m.range(at: 1))
                }
            }
        }
        return best
    }

    public static func isFinance(bundleName: String, title: String, text: String) -> Bool {
        let hay = "\(title)\n\(text)".lowercased()
        let b = bundleName.lowercased()
        return finance.contains(where: hay.contains) || financeAppHints.contains(where: b.contains)
    }
}
