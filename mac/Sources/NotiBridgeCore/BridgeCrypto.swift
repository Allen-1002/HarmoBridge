import CryptoKit
import Foundation

/// 与 docs/protocol.md 中的“密码学约定”（协议 v2）逐项对应；Windows、Android、鸿蒙端必须保持一致。
public enum BridgeCrypto {
    public static let protocolVersion = 2

    /// 消息方向：AAD 不同，把一方的消息反射回去也解不开
    public enum Direction {
        case toComputer
        case toPhone

        var aad: Data { Data((self == .toComputer ? "NB2|p2c" : "NB2|c2p").utf8) }
    }

    public enum CryptoError: Error {
        case badPublicKey
        case badBox
    }

    static let transcriptLabel = Data("NotiBridge-pair-v2".utf8)
    static let infoPairKey = Data("NotiBridge-v2 pair key".utf8)
    static let infoConfirmPhone = Data("NotiBridge-v2 confirm phone".utf8)
    static let infoConfirmComputer = Data("NotiBridge-v2 confirm computer".utf8)

    /// 配对双方都知道的公开信息（字符串按线路上的原样）
    public struct PairingContext: Equatable {
        public var deviceId: String
        public var deviceName: String
        public var phonePlatform: String
        public var macId: String
        public var macName: String
        public var macPlatform: String
        public var phoneNonce: Data
        public var macNonce: Data

        public init(deviceId: String, deviceName: String, phonePlatform: String, macId: String, macName: String,
                    macPlatform: String, phoneNonce: Data, macNonce: Data) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.phonePlatform = phonePlatform
            self.macId = macId
            self.macName = macName
            self.macPlatform = macPlatform
            self.phoneNonce = phoneNonce
            self.macNonce = macNonce
        }

        public var sid: Data { phoneNonce + macNonce }
        public var ci: Data { Cpace.lvCat([Data(deviceId.utf8), Data(macId.utf8)]) }

        public func generator(pin: String) -> Data {
            Cpace.generator(prs: Data(pin.utf8), ci: ci, sid: sid)
        }

        public func transcript(ya: Data, yb: Data) -> Data {
            Cpace.lvCat([transcriptLabel, sid, Data(deviceId.utf8), Data(deviceName.utf8), Data(phonePlatform.utf8),
                         Data(macId.utf8), Data(macName.utf8), Data(macPlatform.utf8), ya, yb])
        }
    }

    /// CPace 完成后两端得到的全部派生值
    public struct PairingKeys {
        public let pairKey: SymmetricKey
        public let transcriptHash: Data
        public let confirmPhone: Data
        public let confirmComputer: Data
        public let sas: String
    }

    /// 由共享点 K 和双方消息派生配对密钥、确认码和 SAS
    public static func pairingKeys(k: Data, context: PairingContext, ya: Data, yb: Data) -> PairingKeys {
        let th = Data(SHA256.hash(data: context.transcript(ya: ya, yb: yb)))
        let ikm = SymmetricKey(data: k)
        func hkdf(_ info: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: th, info: info, outputByteCount: 32)
        }
        let kcP = hkdf(infoConfirmPhone)
        let kcC = hkdf(infoConfirmComputer)
        let cp = Data(HMAC<SHA256>.authenticationCode(for: th + Data("phone".utf8), using: kcP))
        let cc = Data(HMAC<SHA256>.authenticationCode(for: th + Data("computer".utf8), using: kcC))
        return PairingKeys(pairKey: hkdf(infoPairKey), transcriptHash: th, confirmPhone: cp, confirmComputer: cc,
                           sas: sas(transcriptHash: th))
    }

    /// 8 位数字校验码：th 前 5 字节大端整数 mod 10^8，显示为 "1234 5678"
    public static func sas(transcriptHash th: Data) -> String {
        var n: UInt64 = 0
        for b in th.prefix(5) { n = (n << 8) | UInt64(b) }
        let s = String(format: "%08llu", n % 100_000_000)
        return String(s.prefix(4)) + " " + String(s.suffix(4))
    }

    /// 常量时间比较
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    public static func seal(_ key: SymmetricKey, _ plaintext: String, _ dir: Direction) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: AES.GCM.Nonce(), authenticating: dir.aad)
        guard let combined = box.combined else { throw CryptoError.badBox }
        return combined.base64EncodedString()
    }

    public static func open(_ key: SymmetricKey, _ b64: String, _ dir: Direction) throws -> String {
        guard let data = Data(base64Encoded: b64), data.count > 28 else { throw CryptoError.badBox }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key, authenticating: dir.aad)
        guard let s = String(data: plain, encoding: .utf8) else { throw CryptoError.badBox }
        return s
    }

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    public static func randomPin() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
