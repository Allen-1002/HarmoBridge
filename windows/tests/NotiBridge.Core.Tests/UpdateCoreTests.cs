using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

public class UpdateCoreTests
{
    [Theory]
    [InlineData("1.3.0", "1.2.3", 1)]
    [InlineData("v1.3.0", "1.3.0", 0)]
    [InlineData("1.3", "1.3.0", 0)]
    [InlineData("1.10.0", "1.9.9", 1)]
    [InlineData("1.2.9", "1.10.0", -1)]
    [InlineData("2.0.0", "1.99.99", 1)]
    [InlineData("1.3.0-beta", "1.3.0", 0)]
    [InlineData("1.3.0.0", "1.3.0", 0)]
    public void CompareVersions(string a, string b, int expected)
    {
        Assert.Equal(expected, UpdateCore.CompareVersions(a, b));
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("1..0")]
    [InlineData("")]
    [InlineData("1.2.3.4.5")]
    public void InvalidVersions(string v)
    {
        Assert.Null(UpdateCore.CompareVersions(v, "1.0.0"));
        Assert.False(UpdateCore.IsNewer(v, "1.0.0"));
    }

    [Fact]
    public void IsNewer()
    {
        Assert.True(UpdateCore.IsNewer("v1.3.1", "1.3.0"));
        Assert.False(UpdateCore.IsNewer("v1.3.0", "1.3.0"));
        Assert.Equal("1.3.0", UpdateCore.VersionFromTag("v1.3.0"));
    }

    [Fact]
    public void ParseSha256Sums()
    {
        var a = new string('a', 64);
        var b = new string('B', 64);
        var text = $"{a}  NotiBridge-1.3.0-macOS.dmg\r\n{b} *NotiBridge-1.3.0-Windows-x64.zip\n\n# c\nnothex  bad.txt\n{a}  ./dist/NotiBridge-1.3.0-HarmonyOS-unsigned.hap\n";
        var m = UpdateCore.ParseSha256Sums(text);
        Assert.Equal(a, m["NotiBridge-1.3.0-macOS.dmg"]);
        Assert.Equal(b.ToLowerInvariant(), m["NotiBridge-1.3.0-Windows-x64.zip"]);
        Assert.Equal(a, m["NotiBridge-1.3.0-HarmonyOS-unsigned.hap"]);
        Assert.False(m.ContainsKey("bad.txt"));
        Assert.Equal(3, m.Count);
    }

    [Fact]
    public void ParseRelease()
    {
        const string json = """
        {"tag_name":"v1.3.0","html_url":"https://github.com/Allen-1002/NotiBridge/releases/tag/v1.3.0","draft":false,"prerelease":false,
         "body":"简介\n\n## 下载\n| a | b |\n\n## 更新内容\n\n- **自动更新**\n- 版本统一\n\n## 已知限制\n- x",
         "assets":[{"name":"NotiBridge-1.3.0-Windows-x64.zip","browser_download_url":"https://example.com/a.zip","size":123}]}
        """;
        var r = UpdateCore.ParseRelease(json);
        Assert.Equal("1.3.0", r.Version);
        Assert.Equal(123, r.AssetNamed(UpdateCore.WindowsAssetName(r.Version))!.Size);
        // 正文第一行（重点提示）总是放在摘要最前面
        Assert.Equal("简介\n• 自动更新\n• 版本统一", r.NotesSnippet());
    }

    [Fact]
    public void NotesSnippetSurfacesSecurityHeadlineFirst()
    {
        var body = "**安全更新：更新后所有手机都必须重新配对，电脑和手机都要是 1.1.0。**\n\n## 更新内容\n- 改用 CPace\n## 已知限制\n- x";
        Assert.StartsWith("安全更新：更新后所有手机都必须重新配对", UpdateCore.NotesSnippet(body));
    }

    [Fact]
    public void ReleaseSignatureVector()
    {
        var r = TestVectors.Load().GetProperty("releaseSignature");
        var pk = Convert.ToBase64String(Convert.FromHexString(r.GetProperty("publicKey").GetString()!));
        var msg = System.Text.Encoding.UTF8.GetBytes(r.GetProperty("message").GetString()!);
        var sig = System.Text.Encoding.UTF8.GetBytes(r.GetProperty("signature").GetString()! + "\n");
        Assert.True(UpdateCore.VerifySumsSignature(msg, sig, pk));
        var tampered = (byte[])msg.Clone();
        tampered[0] ^= 1;
        Assert.False(UpdateCore.VerifySumsSignature(tampered, sig, pk));
        Assert.False(UpdateCore.VerifySumsSignature(msg, sig), "内置发布公钥不能验证测试签名");
        Assert.False(UpdateCore.VerifySumsSignature(msg, "garbage"u8.ToArray(), pk));
        Assert.Equal(32, Convert.FromBase64String(UpdateCore.ReleasePublicKeyBase64).Length);
    }
}
