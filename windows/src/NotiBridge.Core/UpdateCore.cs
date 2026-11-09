using System.Text.Json;
using System.Text.Json.Serialization;

namespace NotiBridge.Core;

/// <summary>
/// 自动更新用到的纯逻辑：版本号比较、SHA256SUMS.txt 解析、GitHub Release JSON 解析。与 UI 无关，可单元测试。
/// </summary>
public static class UpdateCore
{
    public const string Owner = "Allen-1002";
    public const string Repo = "NotiBridge";
    public const string LatestReleaseUrl = $"https://api.github.com/repos/{Owner}/{Repo}/releases/latest";
    public const string UserAgent = "NotiBridge-Updater";
    public const string SumsAssetName = "SHA256SUMS.txt";
    public const string SumsSignatureAssetName = "SHA256SUMS.txt.sig";

    /// <summary>
    /// 发布签名公钥（Ed25519，32 字节原始格式，Base64）。私钥只在发布者电脑上
    /// （~/.config/notibridge/release-signing-ed25519.pem，scripts/sign_release.sh 使用）。
    /// 与 Mac UpdateCore.swift、Android UpdateCore.kt 中的值必须相同。
    /// </summary>
    public const string ReleasePublicKeyBase64 = "+wkZaT1HzXMHhcMF6xz67byo2x0iNeXMoL4PSO1ApQo=";

    /// <summary>校验 SHA256SUMS.txt 的 Ed25519 签名（.sig 内容为 Base64 的 64 字节签名，允许末尾换行）。</summary>
    public static bool VerifySumsSignature(byte[] sums, byte[] signatureFile, string publicKeyBase64 = ReleasePublicKeyBase64)
    {
        try
        {
            var sig = Convert.FromBase64String(System.Text.Encoding.UTF8.GetString(signatureFile).Trim());
            var pk = Convert.FromBase64String(publicKeyBase64);
            if (sig.Length != 64 || pk.Length != 32) return false;
            var verifier = new Org.BouncyCastle.Crypto.Signers.Ed25519Signer();
            verifier.Init(false, new Org.BouncyCastle.Crypto.Parameters.Ed25519PublicKeyParameters(pk, 0));
            verifier.BlockUpdate(sums, 0, sums.Length);
            return verifier.VerifySignature(sig);
        }
        catch (Exception e) when (e is FormatException or ArgumentException)
        {
            return false;
        }
    }

    public static string WindowsAssetName(string version) => $"NotiBridge-{version}-Windows-x64.zip";

    /// <summary>解析 "v1.3.0" / "1.3" / "1.3.0-beta"；忽略预发布后缀。无法解析返回 null。</summary>
    public static int[]? ParseVersion(string? s)
    {
        if (s is null) return null;
        var t = s.Trim();
        if (t.StartsWith('v') || t.StartsWith('V')) t = t[1..];
        var cut = t.IndexOfAny(['-', '+']);
        if (cut >= 0) t = t[..cut];
        var parts = t.Split('.');
        if (parts.Length is 0 or > 4) return null;
        var result = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            var p = parts[i];
            if (p.Length == 0 || !p.All(char.IsAsciiDigit) || !int.TryParse(p, out var n)) return null;
            result[i] = n;
        }
        return result;
    }

    /// <summary>-1：a 旧；0：相同；1：a 新；无法解析时 null。缺少的段按 0 计。</summary>
    public static int? CompareVersions(string? a, string? b)
    {
        var x = ParseVersion(a);
        var y = ParseVersion(b);
        if (x is null || y is null) return null;
        for (var i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            var l = i < x.Length ? x[i] : 0;
            var r = i < y.Length ? y[i] : 0;
            if (l != r) return l < r ? -1 : 1;
        }
        return 0;
    }

    public static bool IsNewer(string? latest, string? current) => CompareVersions(latest, current) == 1;

    public static string VersionFromTag(string tag)
    {
        var t = tag.Trim();
        return t.StartsWith('v') || t.StartsWith('V') ? t[1..] : t;
    }

    /// <summary>解析 sha256sum 格式（"hash  name" 或 "hash *name"），返回 文件名 → 小写哈希。</summary>
    public static Dictionary<string, string> ParseSha256Sums(string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var sp = line.IndexOfAny([' ', '\t']);
            if (sp <= 0) continue;
            var hash = line[..sp].ToLowerInvariant();
            if (hash.Length != 64 || !hash.All(char.IsAsciiHexDigit)) continue;
            var name = line[sp..].Trim();
            if (name.StartsWith('*')) name = name[1..];
            var slash = name.LastIndexOfAny(['/', '\\']);
            if (slash >= 0) name = name[(slash + 1)..];
            if (name.Length == 0) continue;
            result[name] = hash;
        }
        return result;
    }

    public sealed class Asset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("browser_download_url")] public string BrowserDownloadUrl { get; set; } = "";
        [JsonPropertyName("size")] public long Size { get; set; }
    }

    public sealed class Release
    {
        [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
        [JsonPropertyName("body")] public string? Body { get; set; }
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<Asset> Assets { get; set; } = [];

        [JsonIgnore] public string Version => VersionFromTag(TagName);

        public Asset? AssetNamed(string name) => Assets.FirstOrDefault(a => a.Name == name);

        public string NotesSnippet(int maxChars = 400) => UpdateCore.NotesSnippet(Body ?? "", maxChars);
    }

    public static Release ParseRelease(string json) =>
        JsonSerializer.Deserialize<Release>(json) ?? throw new FormatException("Release JSON 为空");

    /// <summary>摘要 = 正文第一行的重点提示（例如“安全更新，必须重新配对”）+“## 更新内容”一节；去掉表格行和 Markdown 符号。</summary>
    public static string NotesSnippet(string body, int maxChars = 400)
    {
        var all = body.Replace("\r", "").Split('\n').ToList();
        var lines = all;
        // 正文第一行（标题之前、不是表格）总是放在最前面，确保下载前就能看到
        var headline = all.Select(l => l.Trim())
            .FirstOrDefault(l => l.Length > 0 && !l.StartsWith('#') && !l.StartsWith('|') && !l.StartsWith("---"));
        var start = all.FindIndex(l => l.StartsWith('#') && l.Contains("更新内容"));
        if (start >= 0)
        {
            var rest = all.Skip(start + 1).ToList();
            var end = rest.FindIndex(l => l.StartsWith("## "));
            lines = end >= 0 ? rest.Take(end).ToList() : rest;
            if (headline is not null && !lines.Any(l => l.Trim() == headline)) lines.Insert(0, headline);
        }
        var cleaned = string.Join("\n", lines
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('|'))
            .Select(l =>
            {
                var s = l.TrimStart('#', '>').Trim();
                if (s.StartsWith("- ") || s.StartsWith("* ")) s = "• " + s[2..];
                return s.Replace("**", "").Replace("`", "").Trim();
            }));
        return cleaned.Length <= maxChars ? cleaned : cleaned[..maxChars] + "…";
    }
}
