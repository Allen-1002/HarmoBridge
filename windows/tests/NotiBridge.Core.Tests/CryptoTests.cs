using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

/// <summary>
/// 读取 docs/test-vectors/pairing-v2.json：CPace 草案官方向量 + NotiBridge v2 派生向量（独立的 Python 实现计算），
/// 与 Mac、Android、鸿蒙端的测试使用同一个文件。
/// </summary>
public class CryptoTests
{
    [Fact]
    public void OfficialCpaceVectors()
    {
        var o = TestVectors.Load().GetProperty("cpaceOfficial");
        Assert.Equal(Convert.FromHexString("043132333401350003363738"),
            Cpace.LvCat("1234"u8.ToArray(), "5"u8.ToArray(), [], "678"u8.ToArray()));
        Assert.Equal(o.Hex("generatorString"), Cpace.GeneratorString(o.Hex("prs"), o.Hex("ci"), o.Hex("sid")));
        var g = Cpace.Generator(o.Hex("prs"), o.Hex("ci"), o.Hex("sid"));
        Assert.Equal(o.Hex("g"), g);
        Assert.Equal(o.Hex("Ya"), Cpace.ScalarMultVfy(o.Hex("ya"), g));
        Assert.Equal(o.Hex("Yb"), Cpace.ScalarMultVfy(o.Hex("yb"), g));
        Assert.Equal(o.Hex("K"), Cpace.ScalarMultVfy(o.Hex("ya"), o.Hex("Yb")));
        Assert.Equal(o.Hex("K"), Cpace.ScalarMultVfy(o.Hex("yb"), o.Hex("Ya")));
    }

    [Fact]
    public void LowOrderPointsAbort()
    {
        var o = TestVectors.Load().GetProperty("cpaceOfficial");
        var s = o.Hex("lowOrderScalar");
        foreach (var item in o.GetProperty("lowOrder").EnumerateArray())
        {
            if (item.GetProperty("mustAbort").GetBoolean())
                Assert.Throws<System.Security.Cryptography.CryptographicException>(() => Cpace.ScalarMultVfy(s, item.Hex("u")));
            else
                Assert.Equal(item.Hex("q"), Cpace.ScalarMultVfy(s, item.Hex("u")));
        }
    }

    [Fact]
    public void PairingVector()
    {
        var p = TestVectors.Load().GetProperty("pairing");
        var i = p.GetProperty("inputs");
        var o = p.GetProperty("outputs");
        var ctx = new BridgeCrypto.PairingContext(i.Str("deviceId"), i.Str("deviceName"), i.Str("phonePlatform"),
            i.Str("macId"), i.Str("macName"), i.Str("macPlatform"), i.Hex("phoneNonce"), i.Hex("macNonce"));
        Assert.Equal(o.Hex("ci"), ctx.Ci);
        Assert.Equal(o.Hex("sid"), ctx.Sid);
        var g = ctx.Generator(i.Str("pin"));
        Assert.Equal(o.Hex("g"), g);
        var ya = Cpace.ScalarMultVfy(i.Hex("ya"), g);
        var yb = Cpace.ScalarMultVfy(i.Hex("yb"), g);
        Assert.Equal(o.Hex("Ya"), ya);
        Assert.Equal(o.Hex("Yb"), yb);
        var k = Cpace.ScalarMultVfy(i.Hex("yb"), ya);
        Assert.Equal(o.Hex("K"), k);
        Assert.Equal(o.Hex("transcript"), ctx.Transcript(ya, yb));
        var keys = BridgeCrypto.DerivePairingKeys(k, ctx, ya, yb);
        Assert.Equal(o.Hex("transcriptHash"), keys.TranscriptHash);
        Assert.Equal(o.Hex("pairKey"), keys.PairKey);
        Assert.Equal(o.Hex("confirmPhone"), keys.ConfirmPhone);
        Assert.Equal(o.Hex("confirmComputer"), keys.ConfirmComputer);
        Assert.Equal(o.Str("sas"), keys.Sas);

        var w = p.GetProperty("wrongPin");
        Assert.Equal(w.Hex("Ya"), Cpace.ScalarMultVfy(i.Hex("ya"), ctx.Generator(w.Str("pin"))));

        var boxes = p.GetProperty("boxes");
        Assert.Equal(boxes.Str("plaintext"), BridgeCrypto.Open(keys.PairKey, boxes.Str("toComputer"), BridgeCrypto.Direction.ToComputer));
        Assert.Equal(boxes.Str("plaintext"), BridgeCrypto.Open(keys.PairKey, boxes.Str("toPhone"), BridgeCrypto.Direction.ToPhone));
        Assert.False(BridgeCrypto.TryOpen(keys.PairKey, boxes.Str("toComputer"), BridgeCrypto.Direction.ToPhone, out _));
        Assert.False(BridgeCrypto.TryOpen(keys.PairKey, boxes.Str("toPhone"), BridgeCrypto.Direction.ToComputer, out _));
    }

    [Fact]
    public void SealRoundTripAndTamperDetection()
    {
        var key = BridgeCrypto.RandomBytes(32);
        var box = BridgeCrypto.Seal(key, "hello", BridgeCrypto.Direction.ToPhone);
        Assert.Equal("hello", BridgeCrypto.Open(key, box, BridgeCrypto.Direction.ToPhone));
        var raw = Convert.FromBase64String(box);
        raw[^1] ^= 1;
        Assert.False(BridgeCrypto.TryOpen(key, Convert.ToBase64String(raw), BridgeCrypto.Direction.ToPhone, out _));
        Assert.False(BridgeCrypto.TryOpen(BridgeCrypto.RandomBytes(32), box, BridgeCrypto.Direction.ToPhone, out _));
        Assert.False(BridgeCrypto.TryOpen(key, "not base64!", BridgeCrypto.Direction.ToPhone, out _));
    }

    [Fact]
    public void SasFormatAndPin()
    {
        Assert.Equal("0000 0000", BridgeCrypto.Sas(new byte[32]));
        Assert.Equal("1162 7775", BridgeCrypto.Sas(Enumerable.Repeat((byte)0xff, 32).ToArray()));
        for (var i = 0; i < 100; i++) Assert.Matches("^[0-9]{6}$", BridgeCrypto.RandomPin());
    }
}
