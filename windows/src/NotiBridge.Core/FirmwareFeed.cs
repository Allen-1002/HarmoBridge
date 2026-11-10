using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace NotiBridge.Core;

/// <summary>
/// ESP32 固件单独在 GitHub 发布（tag 形如 firmware-v1.2.2，不标记为 Latest，不影响程序自动更新），
/// 电脑端需要时再下载，不打包进安装包。与 Mac 端 FirmwareFeed.swift 一致。
/// </summary>
public static class FirmwareFeed
{
    public const string TagPrefix = "firmware-v";
    public const string ReleasesUrl = $"https://api.github.com/repos/{UpdateCore.Owner}/{UpdateCore.Repo}/releases?per_page=50";

    public static string AssetName(string version) => $"NotiBridge-ESP32-{version}.bin";

    public sealed record Firmware(string Version, UpdateCore.Asset Image, UpdateCore.Asset Sums, UpdateCore.Asset Signature, string Notes);

    /// <summary>从 releases 列表里找最新的固件（跳过草稿、预发布和缺文件的）</summary>
    public static Firmware? Latest(string releasesJson)
    {
        var releases = JsonSerializer.Deserialize<List<UpdateCore.Release>>(releasesJson) ?? [];
        Firmware? best = null;
        foreach (var r in releases)
        {
            if (r.Draft || r.Prerelease || !r.TagName.StartsWith(TagPrefix, StringComparison.Ordinal)) continue;
            var v = r.TagName[TagPrefix.Length..];
            if (UpdateCore.ParseVersion(v) is null) continue;
            if (r.AssetNamed(AssetName(v)) is not { } img || r.AssetNamed(UpdateCore.SumsAssetName) is not { } sums
                || r.AssetNamed(UpdateCore.SumsSignatureAssetName) is not { } sig) continue;
            if (best is not null && !UpdateCore.IsNewer(v, best.Version)) continue;
            best = new Firmware(v, img, sums, sig, r.Body ?? "");
        }
        return best;
    }

    /// <summary>校验签名和哈希，失败抛出异常</summary>
    public static void Verify(byte[] image, string version, byte[] sums, byte[] signature, string publicKeyBase64 = UpdateCore.ReleasePublicKeyBase64)
    {
        if (!UpdateCore.VerifySumsSignature(sums, signature, publicKeyBase64)) throw new InvalidDataException("固件签名校验失败（文件可能被篡改）");
        if (!UpdateCore.ParseSha256Sums(Encoding.UTF8.GetString(sums)).TryGetValue(AssetName(version), out var want))
            throw new InvalidDataException("校验文件里没有这个固件");
        if (Convert.ToHexStringLower(SHA256.HashData(image)) != want) throw new InvalidDataException("固件文件校验不一致，请重新下载");
    }
}
