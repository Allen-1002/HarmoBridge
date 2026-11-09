import CryptoKit
import XCTest
@testable import HarmoBridgeCore

/// 与 windows/tests/HarmoBridge.Core.Tests/CryptoTests.cs 使用同一组测试向量（由独立的 Python cryptography 实现计算），
/// 用来确认 Mac（CryptoKit）与 Windows（BouncyCastle + .NET）遵循同一套密码学约定，可以和同一台手机互通。
final class CryptoVectorTests: XCTestCase {
    private func range(_ start: UInt8) -> Data { Data((0..<32).map { start &+ UInt8($0) }) }
    private let phonePub = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
    private let macPub = "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY="
    private let keyHex = "ae8bedba0583b7bbfa2b0807fd2ddd6b020d39c7fdc62562abb1a936d755dbbd"

    func testSharedVector() throws {
        let phonePriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: range(1))
        let macPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: range(101))
        XCTAssertEqual(phonePriv.publicKey.rawRepresentation.base64EncodedString(), phonePub)
        XCTAssertEqual(macPriv.publicKey.rawRepresentation.base64EncodedString(), macPub)
        let pp = Data(base64Encoded: phonePub)!
        let mp = Data(base64Encoded: macPub)!
        XCTAssertEqual(BridgeCrypto.sas(phonePub: pp, macPub: mp), "491302")
        let key = try BridgeCrypto.derivePairKey(privateKey: macPriv, peerPub: pp, phonePub: pp, macPub: mp, pin: "123456")
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, keyHex)
        XCTAssertEqual(try BridgeCrypto.open(key, "AAAAAAAAAAAAAAAAq0Nf5FBV6VP0KkCm9JQvDAeOprNkTWShWA8qKg=="), "通知 hello")
    }

    func testInfoProbe() {
        final class Empty: PairedKeyStore {
            func key(for deviceId: String) -> SymmetricKey? { nil }
            func save(deviceId: String, name: String, key: SymmetricKey) {}
        }
        let m = SessionMachine(store: Empty(), window: PairingWindow(), macId: "mid", macName: "Mac")
        let outs = m.handle(Envelope(t: "info").json())
        guard case let .send(frame) = outs.first, let env = Envelope.parse(frame) else { return XCTFail("no reply") }
        XCTAssertEqual(env.t, "info")
        XCTAssertEqual(env.macId, "mid")
        XCTAssertEqual(env.platform, "mac")
        XCTAssertTrue(outs.contains(.close("info")))
    }

    func testPairChallengeCarriesPlatform() {
        let env = Envelope(t: "pair_chal", macId: "m", macName: "Mac", platform: "mac", pub: "x")
        XCTAssertTrue(env.json().contains("\"platform\":\"mac\""))
        XCTAssertEqual(Envelope.parse(env.json())?.platform, "mac")
    }
}
