using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

/// <summary>
/// 测试向量由独立实现（Python cryptography 库）按 docs/protocol.md 计算得到，
/// 用来确认 Windows 端与 Mac（CryptoKit）、手机（cryptoFramework）遵循同一套约定。
/// </summary>
public class CryptoTests
{
    private static byte[] Range(int start) => Enumerable.Range(start, 32).Select(i => (byte)i).ToArray();
    private const string PhonePub = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=";
    private const string MacPub = "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY=";
    private const string Key = "ae8bedba0583b7bbfa2b0807fd2ddd6b020d39c7fdc62562abb1a936d755dbbd";

    [Fact]
    public void PublicKeysMatchVector()
    {
        Assert.Equal(PhonePub, Convert.ToBase64String(BridgeCrypto.X25519KeyPair.FromPrivate(Range(1)).PublicRaw));
        Assert.Equal(MacPub, Convert.ToBase64String(BridgeCrypto.X25519KeyPair.FromPrivate(Range(101)).PublicRaw));
    }

    [Fact]
    public void SasAndPairKeyMatchVector()
    {
        var pp = Convert.FromBase64String(PhonePub);
        var mp = Convert.FromBase64String(MacPub);
        Assert.Equal("491302", BridgeCrypto.Sas(pp, mp));
        // 电脑端视角：自己的私钥 + 手机公钥
        var macKey = BridgeCrypto.DerivePairKey(BridgeCrypto.X25519KeyPair.FromPrivate(Range(101)), pp, pp, mp, "123456");
        // 手机端视角
        var phoneKey = BridgeCrypto.DerivePairKey(BridgeCrypto.X25519KeyPair.FromPrivate(Range(1)), mp, pp, mp, "123456");
        Assert.Equal(Key, Convert.ToHexString(macKey).ToLowerInvariant());
        Assert.Equal(macKey, phoneKey);
        var wrongPin = BridgeCrypto.DerivePairKey(BridgeCrypto.X25519KeyPair.FromPrivate(Range(101)), pp, pp, mp, "000000");
        Assert.NotEqual(macKey, wrongPin);
    }

    [Fact]
    public void OpensBoxSealedByOtherImplementation()
    {
        Assert.Equal("通知 hello", BridgeCrypto.Open(Convert.FromHexString(Key), "AAAAAAAAAAAAAAAAq0Nf5FBV6VP0KkCm9JQvDAeOprNkTWShWA8qKg=="));
    }

    [Fact]
    public void SealRoundTripAndTamperDetection()
    {
        var key = BridgeCrypto.RandomBytes(32);
        var box = BridgeCrypto.Seal(key, "pair-confirm-mac");
        Assert.Equal("pair-confirm-mac", BridgeCrypto.Open(key, box));
        var raw = Convert.FromBase64String(box);
        raw[^1] ^= 1;
        Assert.False(BridgeCrypto.TryOpen(key, Convert.ToBase64String(raw), out _));
        Assert.False(BridgeCrypto.TryOpen(BridgeCrypto.RandomBytes(32), box, out _));
    }

    [Fact]
    public void PinIsSixDigits()
    {
        for (var i = 0; i < 100; i++) Assert.Matches("^[0-9]{6}$", BridgeCrypto.RandomPin());
    }
}
