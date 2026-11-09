using System.Security.Cryptography;
using System.Text;

namespace NotiBridge.Core;

/// <summary>
/// 与 docs/protocol.md 中的“密码学约定”（协议 v2）逐项对应，和 Mac BridgeCrypto.swift、Android、鸿蒙端保持一致。
/// </summary>
public static class BridgeCrypto
{
    public const int ProtocolVersion = 2;
    private const int IvLength = 12;
    private const int TagLength = 16;

    /// <summary>消息方向：AAD 不同，把一方的消息反射回去也解不开。</summary>
    public enum Direction { ToComputer, ToPhone }

    private static byte[] Aad(Direction d) => Encoding.UTF8.GetBytes(d == Direction.ToComputer ? "NB2|p2c" : "NB2|c2p");

    private static readonly byte[] TranscriptLabel = Encoding.UTF8.GetBytes("NotiBridge-pair-v2");
    private static readonly byte[] InfoPairKey = Encoding.UTF8.GetBytes("NotiBridge-v2 pair key");
    private static readonly byte[] InfoConfirmPhone = Encoding.UTF8.GetBytes("NotiBridge-v2 confirm phone");
    private static readonly byte[] InfoConfirmComputer = Encoding.UTF8.GetBytes("NotiBridge-v2 confirm computer");

    private static byte[] U(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>配对双方都知道的公开信息（字符串按线路上的原样）。</summary>
    public sealed record PairingContext(string DeviceId, string DeviceName, string PhonePlatform, string MacId,
        string MacName, string MacPlatform, byte[] PhoneNonce, byte[] MacNonce)
    {
        public byte[] Sid => [.. PhoneNonce, .. MacNonce];
        public byte[] Ci => Cpace.LvCat(U(DeviceId), U(MacId));
        public byte[] Generator(string pin) => Cpace.Generator(U(pin), Ci, Sid);

        public byte[] Transcript(byte[] ya, byte[] yb) => Cpace.LvCat(TranscriptLabel, Sid, U(DeviceId), U(DeviceName),
            U(PhonePlatform), U(MacId), U(MacName), U(MacPlatform), ya, yb);
    }

    public sealed record PairingKeys(byte[] PairKey, byte[] TranscriptHash, byte[] ConfirmPhone, byte[] ConfirmComputer,
        string Sas);

    public static PairingKeys DerivePairingKeys(byte[] k, PairingContext ctx, byte[] ya, byte[] yb)
    {
        var th = SHA256.HashData(ctx.Transcript(ya, yb));
        byte[] Hkdf(byte[] info) => HKDF.DeriveKey(HashAlgorithmName.SHA256, k, 32, th, info);
        var kcP = Hkdf(InfoConfirmPhone);
        var kcC = Hkdf(InfoConfirmComputer);
        return new PairingKeys(Hkdf(InfoPairKey), th,
            HMACSHA256.HashData(kcP, (byte[])[.. th, .. U("phone")]),
            HMACSHA256.HashData(kcC, (byte[])[.. th, .. U("computer")]),
            Sas(th));
    }

    /// <summary>8 位数字校验码：th 前 5 字节大端整数 mod 10^8，显示为 "1234 5678"。</summary>
    public static string Sas(byte[] th)
    {
        ulong n = 0;
        for (var i = 0; i < 5; i++) n = (n << 8) | th[i];
        var s = (n % 100_000_000).ToString("D8");
        return s[..4] + " " + s[4..];
    }

    public static bool ConstantTimeEqual(byte[] a, byte[] b) => CryptographicOperations.FixedTimeEquals(a, b);

    /// <summary>AES-256-GCM，输出 Base64(iv ‖ ciphertext ‖ tag16)。</summary>
    public static string Seal(byte[] key, string plaintext, Direction dir)
    {
        var plain = Encoding.UTF8.GetBytes(plaintext);
        var output = new byte[IvLength + plain.Length + TagLength];
        var iv = output.AsSpan(0, IvLength);
        RandomNumberGenerator.Fill(iv);
        using var gcm = new AesGcm(key, TagLength);
        gcm.Encrypt(iv, plain, output.AsSpan(IvLength, plain.Length), output.AsSpan(IvLength + plain.Length), Aad(dir));
        return Convert.ToBase64String(output);
    }

    public static string Open(byte[] key, string b64, Direction dir)
    {
        byte[] data;
        try { data = Convert.FromBase64String(b64); }
        catch (FormatException e) { throw new CryptographicException("bad box", e); }
        if (data.Length <= IvLength + TagLength) throw new CryptographicException("bad box");
        var ctLen = data.Length - IvLength - TagLength;
        var plain = new byte[ctLen];
        using var gcm = new AesGcm(key, TagLength);
        gcm.Decrypt(data.AsSpan(0, IvLength), data.AsSpan(IvLength, ctLen), data.AsSpan(IvLength + ctLen), plain, Aad(dir));
        return Encoding.UTF8.GetString(plain);
    }

    public static bool TryOpen(byte[] key, string? b64, Direction dir, out string plain)
    {
        plain = "";
        if (b64 is null) return false;
        try { plain = Open(key, b64, dir); return true; }
        catch (CryptographicException) { return false; }
    }

    public static byte[] RandomBytes(int count) => RandomNumberGenerator.GetBytes(count);

    public static string RandomPin() => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
}
