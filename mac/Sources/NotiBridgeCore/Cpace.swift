import CryptoKit
import Foundation

/// GF(2^255 - 19) 上的定长运算（4 × 64 位小端 limb），只用于 CPace 的 Elligator2 映射。
/// 不依赖第三方库；每次运算后结果都规约到 [0, p)。
struct Field25519: Equatable {
    var l: [UInt64] // 4 个 limb，小端

    static let zero = Field25519(l: [0, 0, 0, 0])
    static let one = Field25519(l: [1, 0, 0, 0])
    static let p = Field25519(l: [0xFFFF_FFFF_FFFF_FFED, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF])

    init(l: [UInt64]) { self.l = l }

    init(_ small: UInt64) { l = [small, 0, 0, 0] }

    /// 32 字节小端 → 域元素（调用方负责先清掉最高位，这里再按 mod p 规约）
    init(littleEndian b: Data) {
        precondition(b.count == 32)
        var limbs = [UInt64](repeating: 0, count: 4)
        let bytes = [UInt8](b)
        for i in 0..<4 {
            var v: UInt64 = 0
            for j in 0..<8 { v |= UInt64(bytes[i * 8 + j]) << (8 * j) }
            limbs[i] = v
        }
        self = Field25519.reduce256(limbs)
    }

    var littleEndian: Data {
        var out = Data(count: 32)
        for i in 0..<4 {
            for j in 0..<8 { out[i * 8 + j] = UInt8((l[i] >> (8 * j)) & 0xFF) }
        }
        return out
    }

    private static func geq(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where a[i] != b[i] { return a[i] > b[i] }
        return true
    }

    private static func subRaw(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], Bool) {
        var r = [UInt64](repeating: 0, count: 4)
        var borrow = false
        for i in 0..<4 {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            r[i] = d2
            borrow = o1 || o2
        }
        return (r, borrow)
    }

    private static func addRaw(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], UInt64) {
        var r = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (r, carry)
    }

    /// 把任意 256 位值规约到 [0, p)
    private static func reduce256(_ x: [UInt64]) -> Field25519 {
        var v = x
        // 2^255 ≡ 19：把第 255 位折回来（最多两轮）
        for _ in 0..<2 {
            let top = v[3] >> 63
            v[3] &= 0x7FFF_FFFF_FFFF_FFFF
            let (s, _) = addRaw(v, [top * 19, 0, 0, 0])
            v = s
        }
        if geq(v, p.l) { v = subRaw(v, p.l).0 }
        return Field25519(l: v)
    }

    static func + (a: Field25519, b: Field25519) -> Field25519 {
        // a, b < p < 2^255，和 < 2^256，不会溢出
        let (s, _) = addRaw(a.l, b.l)
        return reduce256(s)
    }

    static func - (a: Field25519, b: Field25519) -> Field25519 {
        let (d, borrow) = subRaw(a.l, b.l)
        if !borrow { return Field25519(l: d) }
        let (s, _) = addRaw(d, p.l) // 回绕后加 p
        return Field25519(l: s)
    }

    static prefix func - (a: Field25519) -> Field25519 { zero - a }

    static func * (a: Field25519, b: Field25519) -> Field25519 {
        var t = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = a.l[i].multipliedFullWidth(by: b.l[j])
                let (s1, o1) = t[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[i + j] = s2
                // t + a*b + carry ≤ 2^128 - 1，所以高位加上进位不会溢出
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            t[i + 4] = carry
        }
        // 2^256 ≡ 38 (mod p)：低 256 位 + 38 × 高 256 位
        var r = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = t[i + 4].multipliedFullWidth(by: 38)
            let (s1, o1) = t[i].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        r[4] = carry // ≤ 38
        // 再折一次：r[4] × 2^256 ≡ r[4] × 38
        let (s, c) = addRaw(Array(r[0..<4]), [r[4] * 38, 0, 0, 0])
        var v = s
        if c != 0 {
            // 极少见：又溢出 2^256，再加 38
            v = addRaw(v, [38, 0, 0, 0]).0
        }
        return reduce256(v)
    }

    /// a^e，e 为大端字节的指数
    func pow(_ eBigEndian: [UInt8]) -> Field25519 {
        var r = Field25519.one
        for byte in eBigEndian {
            for bit in stride(from: 7, through: 0, by: -1) {
                r = r * r
                if (byte >> UInt8(bit)) & 1 == 1 { r = r * self }
            }
        }
        return r
    }

    /// p - 2 与 (p - 1) / 2 的大端字节
    static let pMinus2: [UInt8] = [0x7F] + [UInt8](repeating: 0xFF, count: 30) + [0xEB]
    static let pMinus1Half: [UInt8] = [0x3F] + [UInt8](repeating: 0xFF, count: 30) + [0xF6]

    func inverse() -> Field25519 { pow(Field25519.pMinus2) }

    /// 欧拉判别式：0（零）、1（平方数）或 p-1（非平方数）
    func legendre() -> Field25519 { pow(Field25519.pMinus1Half) }
}

/// CPace（draft-irtf-cfrg-cpace-21，CPACE-X25519-SHA512）中 NotiBridge 用到的部分。
/// 与 Windows Cpace.cs、Android Cpace.kt、鸿蒙 Cpace.ets 逐项一致，测试向量见 docs/test-vectors/pairing-v2.json。
public enum Cpace {
    public static let dsi = Data("CPace255".utf8)
    static let sInBytes = 128
    static let curveA = Field25519(486_662)

    public enum CpaceError: Error {
        case badPoint
        case lowOrder
    }

    public static func prependLen(_ data: Data) -> Data {
        var length = data.count
        var out = Data()
        repeat {
            if length < 128 {
                out.append(UInt8(length))
            } else {
                out.append(UInt8((length & 0x7F) + 0x80))
            }
            length >>= 7
        } while length != 0
        return out + data
    }

    public static func lvCat(_ items: [Data]) -> Data {
        items.reduce(Data()) { $0 + prependLen($1) }
    }

    public static func generatorString(prs: Data, ci: Data, sid: Data) -> Data {
        let zpad = max(0, sInBytes - 1 - prependLen(prs).count - prependLen(dsi).count)
        return lvCat([dsi, prs, Data(count: zpad), ci, sid])
    }

    /// Elligator2（草案附录 A.5）：输入 u 坐标字节（已清最高位），输出曲线上点的 u 坐标
    static func elligator2(_ r: Field25519) -> Field25519 {
        let two = Field25519(2)
        let v = -(curveA * (Field25519.one + two * r * r).inverse())
        let gx = v * v * v + curveA * v * v + v
        let eps = gx.legendre()
        let halfA = curveA * two.inverse()
        return eps * v - (Field25519.one - eps) * halfA
    }

    /// 生成元 g（32 字节小端 u 坐标）
    public static func generator(prs: Data, ci: Data, sid: Data) -> Data {
        let hash = Data(SHA512.hash(data: generatorString(prs: prs, ci: ci, sid: sid))).prefix(32)
        var u = Data(hash)
        u[31] &= 0x7F
        return elligator2(Field25519(littleEndian: u)).littleEndian
    }

    /// X25519(scalar, u)，结果为全 0（低阶点）时抛错。使用 CryptoKit 的常量时间实现。
    public static func scalarMultVfy(scalar: Data, point: Data) throws -> Data {
        guard scalar.count == 32, point.count == 32,
              let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar),
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point) else {
            throw CpaceError.badPoint
        }
        let shared: SharedSecret
        do {
            shared = try priv.sharedSecretFromKeyAgreement(with: pub)
        } catch {
            throw CpaceError.lowOrder // CryptoKit 对全 0 结果抛错
        }
        let out = shared.withUnsafeBytes { Data($0) }
        if out.allSatisfy({ $0 == 0 }) { throw CpaceError.lowOrder }
        return out
    }
}
