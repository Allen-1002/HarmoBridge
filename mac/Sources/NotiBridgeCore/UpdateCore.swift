import Foundation

/// 自动更新用到的纯逻辑：版本号比较、SHA256SUMS.txt 解析、GitHub Release JSON 解析。与 UI 无关，可单元测试。
public enum UpdateCore {
    public static let owner = "Allen-1002"
    public static let repo = "NotiBridge"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    public static let userAgent = "NotiBridge-Updater"

    /// 解析 "v1.3.0" / "1.3" / "1.3.0-beta" 之类的版本号为数字数组；无法解析返回 nil。
    /// 预发布后缀（- 或 + 之后）被忽略。
    public static func parseVersion(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let cut = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<cut]) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// 比较两个版本号：-1 表示 a < b，0 相等，1 表示 a > b。缺少的段按 0 计（1.3 == 1.3.0）。
    /// 无法解析时返回 nil。
    public static func compareVersions(_ a: String, _ b: String) -> Int? {
        guard let x = parseVersion(a), let y = parseVersion(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// latest 是否比 current 新（无法解析时视为不新）
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        compareVersions(latest, current) == 1
    }

    /// 去掉 tag 前缀 v："v1.3.0" -> "1.3.0"
    public static func versionString(fromTag tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// 解析 sha256sum 格式："<64 位十六进制>  <文件名>"（二进制模式为 " *<文件名>"）。
    /// 返回 文件名 -> 小写十六进制哈希。忽略空行、注释和格式不对的行。
    public static func parseSha256Sums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = line[..<space].lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var name = line[space...].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            // 只取文件名部分（有的工具会写 ./dist/xxx）
            if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
            guard !name.isEmpty else { continue }
            result[name] = hash
        }
        return result
    }

    /// 各平台安装包文件名（与 Release 资源命名一致）
    public static func macAssetName(version: String) -> String { "NotiBridge-\(version)-macOS.dmg" }
    public static let sumsAssetName = "SHA256SUMS.txt"

    public struct Asset: Decodable, Equatable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    public struct Release: Decodable, Equatable {
        public let tagName: String
        public let name: String?
        public let htmlURL: URL
        public let body: String?
        public let draft: Bool
        public let prerelease: Bool
        public let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
            case assets
        }

        public var version: String { UpdateCore.versionString(fromTag: tagName) }

        public func asset(named n: String) -> Asset? { assets.first { $0.name == n } }

        /// 更新说明摘要：去掉 Markdown 表格、标题符号，截取前 maxChars 个字符
        public func notesSnippet(maxChars: Int = 400) -> String {
            UpdateCore.notesSnippet(body ?? "", maxChars: maxChars)
        }
    }

    public static func decodeRelease(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }

    /// 优先取“## 更新内容”一节；去掉表格行和 Markdown 符号
    public static func notesSnippet(_ body: String, maxChars: Int = 400) -> String {
        var lines = body.components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { $0.hasPrefix("#") && $0.contains("更新内容") }) {
            let rest = lines[(start + 1)...]
            let end = rest.firstIndex(where: { $0.hasPrefix("## ") }) ?? rest.endIndex
            lines = Array(rest[..<end])
        }
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("|") }
            .map { l -> String in
                var s = l
                while s.hasPrefix("#") { s.removeFirst() }
                if s.hasPrefix("- ") || s.hasPrefix("* ") { s = "• " + s.dropFirst(2) }
                return s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
        if cleaned.count <= maxChars { return cleaned }
        return String(cleaned.prefix(maxChars)) + "…"
    }
}
