import CryptoKit
import Foundation

/// 电脑端保存已配对手机密钥的本地加密文件格式（v1）。
///
/// 文件内容 = "NBPF1" + AES-GCM(combined: nonce + 密文 + tag)，明文是 [PairingRecord] 的 JSON。
/// 文件密钥由“本机硬件 UUID + 这台电脑的 macId”经 HKDF-SHA256 派生，只用于让文件绑定这台电脑：
/// 把文件复制到别的电脑上无法解密。
/// 注意：它**不能**防止以同一用户身份运行的其他程序读取（它们同样能拿到硬件 UUID 和 macId）；
/// 安全性依赖文件权限（目录 0700、文件 0600）和 macOS 的用户隔离。用它代替钥匙串是为了
/// 避免每次更新后 macOS 反复询问钥匙串授权（自签名应用没有团队 ID，钥匙串只能按 cdhash 记录授权）。
public enum PairingFile {
    public struct Record: Codable, Equatable {
        public var id: String
        public var name: String
        public var key: Data
        public var pairedAt: Date

        public init(id: String, name: String, key: Data, pairedAt: Date) {
            self.id = id
            self.name = name
            self.key = key
            self.pairedAt = pairedAt
        }
    }

    public enum Failure: Error, Equatable {
        case badMagic
        case decryptFailed
        case badContent
    }

    static let magic = Data("NBPF1".utf8)
    static let info = Data("NotiBridge-pairing-file-v1".utf8)

    /// 由本机硬件标识和 macId 派生文件密钥
    public static func fileKey(machineId: String, macId: String) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data("\(machineId)|\(macId)".utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: info, info: info, outputByteCount: 32)
    }

    public static func seal(_ records: [Record], key: SymmetricKey) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .sortedKeys
        let plain = try enc.encode(records)
        let box = try AES.GCM.seal(plain, using: key, authenticating: magic)
        guard let combined = box.combined else { throw Failure.badContent }
        return magic + combined
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> [Record] {
        guard data.count > magic.count, data.prefix(magic.count) == magic else { throw Failure.badMagic }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            plain = try AES.GCM.open(box, using: key, authenticating: magic)
        } catch {
            throw Failure.decryptFailed
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let records = try? dec.decode([Record].self, from: plain),
              records.allSatisfy({ $0.key.count == 32 }) else { throw Failure.badContent }
        return records
    }
}
