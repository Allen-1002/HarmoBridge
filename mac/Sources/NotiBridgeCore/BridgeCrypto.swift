import CryptoKit
import Foundation

/// 与 docs/protocol.md 中的“密码学约定”逐项对应，鸿蒙端 Crypto.ets 必须保持一致。
public enum BridgeCrypto {
    public static let aad = Data("HB1".utf8)
    public static let pairInfoPrefix = "HarmoBridge-pair-v1|"

    public enum CryptoError: Error {
        case badPublicKey
        case badBox
    }

    public static func transcript(phonePub: Data, macPub: Data) -> Data {
        phonePub + macPub
    }

    public static func salt(phonePub: Data, macPub: Data) -> Data {
        Data(SHA256.hash(data: transcript(phonePub: phonePub, macPub: macPub)))
    }

    /// 6 位十六进制校验码，两端显示给用户比对。
    public static func sas(phonePub: Data, macPub: Data) -> String {
        salt(phonePub: phonePub, macPub: macPub).prefix(3).map { String(format: "%02X", $0) }.joined()
    }

    public static func derivePairKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPub: Data,
        phonePub: Data,
        macPub: Data,
        pin: String
    ) throws -> SymmetricKey {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub) else {
            throw CryptoError.badPublicKey
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt(phonePub: phonePub, macPub: macPub),
            sharedInfo: Data((pairInfoPrefix + pin).utf8),
            outputByteCount: 32
        )
    }

    public static func seal(_ key: SymmetricKey, _ plaintext: String) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw CryptoError.badBox }
        return combined.base64EncodedString()
    }

    public static func open(_ key: SymmetricKey, _ b64: String) throws -> String {
        guard let data = Data(base64Encoded: b64), data.count > 28 else { throw CryptoError.badBox }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key, authenticating: aad)
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
