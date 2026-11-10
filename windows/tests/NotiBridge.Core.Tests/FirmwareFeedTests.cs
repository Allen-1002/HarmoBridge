using System.Security.Cryptography;
using System.Text;
using NotiBridge.Core;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using Xunit;

namespace NotiBridge.Core.Tests;

public class FirmwareFeedTests
{
    private static string Release(string tag, bool draft = false, bool pre = false, params string[] files) =>
        $$"""{"tag_name":"{{tag}}","name":"x","html_url":"https://example.com","body":"说明","draft":{{(draft ? "true" : "false")}},"prerelease":{{(pre ? "true" : "false")}},"assets":[{{string.Join(",", files.Select(f => $$"""{"name":"{{f}}","browser_download_url":"https://example.com/{{f}}","size":10}"""))}}]}""";

    private static string[] Full(string v) => [$"NotiBridge-ESP32-{v}.bin", "SHA256SUMS.txt", "SHA256SUMS.txt.sig"];

    [Fact]
    public void PicksNewestCompleteFirmwareRelease()
    {
        var json = "[" + string.Join(",",
            Release("v1.3.0", false, false, "NotiBridge-1.3.0-macOS.dmg", "SHA256SUMS.txt", "SHA256SUMS.txt.sig"),
            Release("firmware-v1.2.9", true, false, Full("1.2.9")),
            Release("firmware-v1.2.8", false, true, Full("1.2.8")),
            Release("firmware-v1.2.7", false, false, "NotiBridge-ESP32-1.2.7.bin"),
            Release("firmware-v1.2.2", false, false, Full("1.2.2")),
            Release("firmware-v1.2.10", false, false, Full("1.2.10"))) + "]";
        var fw = FirmwareFeed.Latest(json);
        Assert.NotNull(fw);
        Assert.Equal("1.2.10", fw!.Version);
        Assert.Null(FirmwareFeed.Latest("[]"));
    }

    [Fact]
    public void Verify()
    {
        var priv = new Ed25519PrivateKeyParameters(new SecureRandom());
        var pub = Convert.ToBase64String(priv.GeneratePublicKey().GetEncoded());
        byte[] image = [1, 2, 3];
        var sums = Encoding.UTF8.GetBytes($"{Convert.ToHexStringLower(SHA256.HashData(image))}  NotiBridge-ESP32-1.2.2.bin\n");
        var signer = new Ed25519Signer();
        signer.Init(true, priv);
        signer.BlockUpdate(sums, 0, sums.Length);
        var sig = Encoding.UTF8.GetBytes(Convert.ToBase64String(signer.GenerateSignature()));
        FirmwareFeed.Verify(image, "1.2.2", sums, sig, pub);
        Assert.Throws<InvalidDataException>(() => FirmwareFeed.Verify([9], "1.2.2", sums, sig, pub));
        Assert.Throws<InvalidDataException>(() => FirmwareFeed.Verify(image, "1.2.3", sums, sig, pub));
        Assert.Throws<InvalidDataException>(() => FirmwareFeed.Verify(image, "1.2.2", sums, sig));
    }
}
