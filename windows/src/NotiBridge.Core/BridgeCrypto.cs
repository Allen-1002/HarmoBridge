using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace NotiBridge.Core;

/// <summary>
/// 与 docs/protocol.md 中的“密码学约定”逐项对应，和 Mac 端 BridgeCrypto.swift、手机端 Crypto.ets 必须保持一致。
/// </summary>
public static class BridgeCrypto
{
    public static readonly byte[] Aad = Encoding.UTF8.GetBytes("HB1");
    public const string PairInfoPrefix = "HarmoBridge-pair-v1|";
    private const int IvLength = 12;
    private const int TagLength = 16;

    public sealed class X25519KeyPair
    {
        internal X25519PrivateKeyParameters Private { get; }
        public byte[] PublicRaw { get; }

        internal X25519KeyPair(X25519PrivateKeyParameters priv)
        {
            Private = priv;
            PublicRaw = priv.GeneratePublicKey().GetEncoded();
        }

        public static X25519KeyPair Generate() => new(new X25519PrivateKeyParameters(new SecureRandom()));

        /// <summary>仅测试用：由 32 字节私钥构造。</summary>
        public static X25519KeyPair FromPrivate(byte[] raw) => new(new X25519PrivateKeyParameters(raw, 0));
    }

    public static byte[] Salt(byte[] phonePub, byte[] macPub) => SHA256.HashData([.. phonePub, .. macPub]);

    /// <summary>6 位十六进制校验码，两端显示给用户比对。</summary>
    public static string Sas(byte[] phonePub, byte[] macPub) =>
        Convert.ToHexString(Salt(phonePub, macPub), 0, 3);

    public static byte[] SharedSecret(X25519KeyPair mine, byte[] peerPub)
    {
        if (peerPub.Length != 32) throw new CryptographicException("bad public key");
        var agreement = new X25519Agreement();
        agreement.Init(mine.Private);
        var shared = new byte[agreement.AgreementSize];
        agreement.CalculateAgreement(new X25519PublicKeyParameters(peerPub, 0), shared, 0);
        if (shared.All(b => b == 0)) throw new CryptographicException("low-order public key");
        return shared;
    }

    public static byte[] DerivePairKey(X25519KeyPair mine, byte[] peerPub, byte[] phonePub, byte[] macPub, string pin)
    {
        var shared = SharedSecret(mine, peerPub);
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, Salt(phonePub, macPub),
            Encoding.UTF8.GetBytes(PairInfoPrefix + pin));
    }

    /// <summary>AES-256-GCM，输出 Base64(iv ‖ ciphertext ‖ tag16)。</summary>
    public static string Seal(byte[] key, string plaintext)
    {
        var plain = Encoding.UTF8.GetBytes(plaintext);
        var output = new byte[IvLength + plain.Length + TagLength];
        var iv = output.AsSpan(0, IvLength);
        RandomNumberGenerator.Fill(iv);
        using var gcm = new AesGcm(key, TagLength);
        gcm.Encrypt(iv, plain, output.AsSpan(IvLength, plain.Length), output.AsSpan(IvLength + plain.Length), Aad);
        return Convert.ToBase64String(output);
    }

    public static string Open(byte[] key, string b64)
    {
        byte[] data;
        try { data = Convert.FromBase64String(b64); }
        catch (FormatException e) { throw new CryptographicException("bad box", e); }
        if (data.Length <= IvLength + TagLength) throw new CryptographicException("bad box");
        var ctLen = data.Length - IvLength - TagLength;
        var plain = new byte[ctLen];
        using var gcm = new AesGcm(key, TagLength);
        gcm.Decrypt(data.AsSpan(0, IvLength), data.AsSpan(IvLength, ctLen), data.AsSpan(IvLength + ctLen), plain, Aad);
        return Encoding.UTF8.GetString(plain);
    }

    public static bool TryOpen(byte[] key, string? b64, out string plain)
    {
        plain = "";
        if (b64 is null) return false;
        try { plain = Open(key, b64); return true; }
        catch (CryptographicException) { return false; }
    }

    public static byte[] RandomBytes(int count) => RandomNumberGenerator.GetBytes(count);

    public static string RandomPin() => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
}
