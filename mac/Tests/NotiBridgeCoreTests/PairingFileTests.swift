import CryptoKit
import XCTest
@testable import NotiBridgeCore

final class PairingFileTests: XCTestCase {
    private func sample() -> [PairingFile.Record] {
        [
            .init(id: "dev1", name: "HUAWEI Mate 60 Pro+", key: Data(repeating: 1, count: 32),
                  pairedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(id: "dev2", name: "手机 2", key: Data((0..<32).map { UInt8($0) }),
                  pairedAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]
    }

    func testRoundTrip() throws {
        let key = PairingFile.fileKey(machineId: "UUID-A", macId: "mac-1")
        let data = try PairingFile.seal(sample(), key: key)
        XCTAssertEqual(try PairingFile.open(data, key: key), sample())
        // 明文里的名字和密钥不能出现在文件中
        XCTAssertNil(data.range(of: Data("dev1".utf8)))
    }

    func testEmptyList() throws {
        let key = PairingFile.fileKey(machineId: "UUID-A", macId: "mac-1")
        XCTAssertEqual(try PairingFile.open(try PairingFile.seal([], key: key), key: key), [])
    }

    func testOtherMachineOrMacIdCannotOpen() throws {
        let data = try PairingFile.seal(sample(), key: PairingFile.fileKey(machineId: "UUID-A", macId: "mac-1"))
        XCTAssertThrowsError(try PairingFile.open(data, key: PairingFile.fileKey(machineId: "UUID-B", macId: "mac-1"))) {
            XCTAssertEqual($0 as? PairingFile.Failure, .decryptFailed)
        }
        XCTAssertThrowsError(try PairingFile.open(data, key: PairingFile.fileKey(machineId: "UUID-A", macId: "mac-2"))) {
            XCTAssertEqual($0 as? PairingFile.Failure, .decryptFailed)
        }
    }

    func testCorruptFile() throws {
        let key = PairingFile.fileKey(machineId: "UUID-A", macId: "mac-1")
        var data = try PairingFile.seal(sample(), key: key)
        data[data.count - 5] ^= 0xFF
        XCTAssertThrowsError(try PairingFile.open(data, key: key)) {
            XCTAssertEqual($0 as? PairingFile.Failure, .decryptFailed)
        }
        XCTAssertThrowsError(try PairingFile.open(Data("garbage".utf8), key: key)) {
            XCTAssertEqual($0 as? PairingFile.Failure, .badMagic)
        }
        XCTAssertThrowsError(try PairingFile.open(Data(), key: key))
    }

    func testKeyDerivationIsStable() {
        let a = PairingFile.fileKey(machineId: "UUID-A", macId: "mac-1")
        let b = PairingFile.fileKey(machineId: "UUID-A", macId: "mac-1")
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }
}
