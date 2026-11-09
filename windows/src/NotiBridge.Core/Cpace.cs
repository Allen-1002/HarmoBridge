using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Math.EC.Rfc7748;

namespace NotiBridge.Core;

/// <summary>
/// CPace（draft-irtf-cfrg-cpace-21，CPACE-X25519-SHA512）中 NotiBridge 用到的部分，
/// 与 Mac Cpace.swift、Android Cpace.kt、鸿蒙 Cpace.ets 逐项一致（docs/test-vectors/pairing-v2.json）。
/// Elligator2 用 System.Numerics.BigInteger；X25519 用 BouncyCastle 的常量时间实现。
/// </summary>
public static class Cpace
{
    public static readonly byte[] Dsi = Encoding.UTF8.GetBytes("CPace255");
    private const int SInBytes = 128;
    private static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
    private static readonly BigInteger A = 486662;

    public static byte[] PrependLen(byte[] data)
    {
        var len = data.Length;
        var out_ = new List<byte>();
        do
        {
            out_.Add(len < 128 ? (byte)len : (byte)((len & 0x7f) + 0x80));
            len >>= 7;
        } while (len != 0);
        out_.AddRange(data);
        return [.. out_];
    }

    public static byte[] LvCat(params byte[][] items) => items.SelectMany(PrependLen).ToArray();

    public static byte[] GeneratorString(byte[] prs, byte[] ci, byte[] sid)
    {
        var zpad = Math.Max(0, SInBytes - 1 - PrependLen(prs).Length - PrependLen(Dsi).Length);
        return LvCat(Dsi, prs, new byte[zpad], ci, sid);
    }

    private static BigInteger Mod(BigInteger x) => ((x % P) + P) % P;

    private static BigInteger DecodeLe(byte[] b) => new(b, isUnsigned: true, isBigEndian: false);

    private static byte[] EncodeLe(BigInteger x)
    {
        var raw = Mod(x).ToByteArray(isUnsigned: true, isBigEndian: false);
        var out_ = new byte[32];
        Array.Copy(raw, out_, Math.Min(32, raw.Length));
        return out_;
    }

    /// <summary>Elligator2（草案附录 A.5）：v = -A/(1+2r²)，ε = legendre(v³+Av²+v)，x = εv − (1−ε)A/2。</summary>
    internal static BigInteger Elligator2(BigInteger r)
    {
        var v = Mod(-A * BigInteger.ModPow(Mod(1 + 2 * r * r), P - 2, P));
        var eps = BigInteger.ModPow(Mod(v * v * v + A * v * v + v), (P - 1) / 2, P);
        var halfA = Mod(A * BigInteger.ModPow(2, P - 2, P));
        return Mod(eps * v - (1 - eps) * halfA);
    }

    /// <summary>生成元 g（32 字节小端 u 坐标）。</summary>
    public static byte[] Generator(byte[] prs, byte[] ci, byte[] sid)
    {
        var hash = SHA512.HashData(GeneratorString(prs, ci, sid)).AsSpan(0, 32).ToArray();
        hash[31] &= 0x7f;
        return EncodeLe(Elligator2(DecodeLe(hash)));
    }

    /// <summary>X25519(scalar, point)；结果全 0（低阶点）时抛 CryptographicException。</summary>
    public static byte[] ScalarMultVfy(byte[] scalar, byte[] point)
    {
        if (scalar.Length != 32 || point.Length != 32) throw new CryptographicException("bad point length");
        var r = new byte[32];
        if (!X25519.CalculateAgreement(scalar, 0, point, 0, r, 0)) throw new CryptographicException("low-order point");
        return r;
    }
}
