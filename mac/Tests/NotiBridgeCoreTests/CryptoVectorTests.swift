import CryptoKit
import XCTest
@testable import NotiBridgeCore

/// 读取 docs/test-vectors/pairing-v2.json：CPace 草案官方向量 + NotiBridge v2 派生向量（由独立的 Python 实现计算）。
/// Windows、Android、鸿蒙端的单元测试读取同一个文件。
final class CryptoVectorTests: XCTestCase {
    func testOfficialCpaceVectors() throws {
        let o = try loadVectors()["cpaceOfficial"] as! [String: Any]
        let s = { (k: String) in hexData(o[k] as! String) }
        XCTAssertEqual(Cpace.lvCat([Data("1234".utf8), Data("5".utf8), Data(), Data("678".utf8)]),
                       hexData("043132333401350003363738"))
        XCTAssertEqual(Cpace.prependLen(Data(count: 128)).prefix(2), hexData("8001"))
        XCTAssertEqual(Cpace.generatorString(prs: s("prs"), ci: s("ci"), sid: s("sid")), s("generatorString"))
        let g = Cpace.generator(prs: s("prs"), ci: s("ci"), sid: s("sid"))
        XCTAssertEqual(hexString(g), o["g"] as? String)
        XCTAssertEqual(try Cpace.scalarMultVfy(scalar: s("ya"), point: g), s("Ya"))
        XCTAssertEqual(try Cpace.scalarMultVfy(scalar: s("yb"), point: g), s("Yb"))
        XCTAssertEqual(try Cpace.scalarMultVfy(scalar: s("ya"), point: s("Yb")), s("K"))
        XCTAssertEqual(try Cpace.scalarMultVfy(scalar: s("yb"), point: s("Ya")), s("K"))
    }

    func testLowOrderPointsAbort() throws {
        let o = try loadVectors()["cpaceOfficial"] as! [String: Any]
        let scalar = hexData(o["lowOrderScalar"] as! String)
        for item in o["lowOrder"] as! [[String: Any]] {
            let u = hexData(item["u"] as! String)
            if item["mustAbort"] as! Bool {
                XCTAssertThrowsError(try Cpace.scalarMultVfy(scalar: scalar, point: u), "\(item["u"]!)")
            } else {
                XCTAssertEqual(hexString(try Cpace.scalarMultVfy(scalar: scalar, point: u)), item["q"] as? String)
            }
        }
    }

    func testPairingVector() throws {
        let p = try loadVectors()["pairing"] as! [String: Any]
        let i = p["inputs"] as! [String: String]
        let out = p["outputs"] as! [String: String]
        let ctx = BridgeCrypto.PairingContext(
            deviceId: i["deviceId"]!, deviceName: i["deviceName"]!, phonePlatform: i["phonePlatform"]!,
            macId: i["macId"]!, macName: i["macName"]!, macPlatform: i["macPlatform"]!,
            phoneNonce: hexData(i["phoneNonce"]!), macNonce: hexData(i["macNonce"]!))
        XCTAssertEqual(hexString(ctx.ci), out["ci"])
        XCTAssertEqual(hexString(ctx.sid), out["sid"])
        XCTAssertEqual(hexString(Cpace.generatorString(prs: Data(i["pin"]!.utf8), ci: ctx.ci, sid: ctx.sid)),
                       out["generatorString"])
        let g = ctx.generator(pin: i["pin"]!)
        XCTAssertEqual(hexString(g), out["g"])
        let ya = try Cpace.scalarMultVfy(scalar: hexData(i["ya"]!), point: g)
        let yb = try Cpace.scalarMultVfy(scalar: hexData(i["yb"]!), point: g)
        XCTAssertEqual(hexString(ya), out["Ya"])
        XCTAssertEqual(hexString(yb), out["Yb"])
        let k = try Cpace.scalarMultVfy(scalar: hexData(i["ya"]!), point: yb)
        XCTAssertEqual(hexString(k), out["K"])
        XCTAssertEqual(hexString(ctx.transcript(ya: ya, yb: yb)), out["transcript"])
        let keys = BridgeCrypto.pairingKeys(k: k, context: ctx, ya: ya, yb: yb)
        XCTAssertEqual(hexString(keys.transcriptHash), out["transcriptHash"])
        XCTAssertEqual(hexString(keys.pairKey.withUnsafeBytes { Data($0) }), out["pairKey"])
        XCTAssertEqual(hexString(keys.confirmPhone), out["confirmPhone"])
        XCTAssertEqual(hexString(keys.confirmComputer), out["confirmComputer"])
        XCTAssertEqual(keys.sas, out["sas"])

        // 错误 PIN：Ya 和配对密钥都不同
        let w = p["wrongPin"] as! [String: String]
        let gw = ctx.generator(pin: w["pin"]!)
        let yaw = try Cpace.scalarMultVfy(scalar: hexData(i["ya"]!), point: gw)
        XCTAssertEqual(hexString(yaw), w["Ya"])

        // AES-GCM 方向分离：两个方向的样本只能用对应方向打开
        let boxes = p["boxes"] as! [String: String]
        XCTAssertEqual(try BridgeCrypto.open(keys.pairKey, boxes["toComputer"]!, .toComputer), boxes["plaintext"])
        XCTAssertEqual(try BridgeCrypto.open(keys.pairKey, boxes["toPhone"]!, .toPhone), boxes["plaintext"])
        XCTAssertThrowsError(try BridgeCrypto.open(keys.pairKey, boxes["toComputer"]!, .toPhone))
        XCTAssertThrowsError(try BridgeCrypto.open(keys.pairKey, boxes["toPhone"]!, .toComputer))
    }

    func testReleaseSignatureVector() throws {
        let r = try loadVectors()["releaseSignature"] as! [String: String]
        let pk = hexData(r["publicKey"]!).base64EncodedString()
        let msg = Data(r["message"]!.utf8)
        let sig = Data((r["signature"]! + "\n").utf8)
        XCTAssertTrue(UpdateCore.verifySumsSignature(sums: msg, signatureFile: sig, publicKeyBase64: pk))
        var tampered = msg
        tampered[0] ^= 1
        XCTAssertFalse(UpdateCore.verifySumsSignature(sums: tampered, signatureFile: sig, publicKeyBase64: pk))
        // 内置的发布公钥不是测试密钥，不能验证测试签名
        XCTAssertFalse(UpdateCore.verifySumsSignature(sums: msg, signatureFile: sig))
        XCTAssertFalse(UpdateCore.verifySumsSignature(sums: msg, signatureFile: Data("garbage".utf8), publicKeyBase64: pk))
        XCTAssertEqual(Data(base64Encoded: UpdateCore.releasePublicKeyBase64)?.count, 32)
    }

    func testFieldArithmeticAgainstKnownValues() {
        // (p-1)·(p-1) = 1，2·inv(2) = 1；p ≡ 1 (mod 4) 所以 -1 是平方数，2 不是
        let minusOne = -Field25519.one
        XCTAssertEqual(minusOne * minusOne, Field25519.one)
        XCTAssertEqual(Field25519(2) * Field25519(2).inverse(), Field25519.one)
        XCTAssertEqual(minusOne.legendre(), Field25519.one)
        XCTAssertEqual(Field25519(2).legendre(), minusOne) // 2 是非平方数（Elligator2 的 Z）
        XCTAssertEqual(Field25519(0).legendre(), Field25519.zero)
        XCTAssertEqual(Field25519(littleEndian: Field25519.p.littleEndian), Field25519.zero) // p 规约为 0
    }

    func testSasFormat() {
        XCTAssertEqual(BridgeCrypto.sas(transcriptHash: Data(count: 32)), "0000 0000")
        let s = BridgeCrypto.sas(transcriptHash: Data(repeating: 0xFF, count: 32))
        XCTAssertEqual(s.count, 9)
        XCTAssertEqual(s, "1162 7775") // (2^40 - 1) mod 10^8
    }

    func testInfoProbe() {
        let m = SessionMachine(store: MemoryStore(), window: PairingWindow(), macId: "mid", macName: "Mac")
        let outs = m.handle(Envelope(t: "info").json())
        guard case let .send(frame) = outs.first, let env = Envelope.parse(frame) else { return XCTFail("no reply") }
        XCTAssertEqual(env.t, "info")
        XCTAssertEqual(env.v, 2)
        XCTAssertEqual(env.macId, "mid")
        XCTAssertEqual(env.platform, "mac")
        XCTAssertTrue(outs.contains(.close("info")))
    }
}
