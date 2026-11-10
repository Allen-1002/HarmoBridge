import CryptoKit
import Foundation

/// ESP32 固件单独在 GitHub 发布（tag 形如 firmware-v1.2.2，不标记为 Latest，不影响 App 自动更新），
/// 电脑端需要时再下载，不打包进安装包。与 Windows 端 FirmwareFeed.cs 一致。
///
/// 每个固件 Release 包含：NotiBridge-ESP32-<版本>.bin、SHA256SUMS.txt、SHA256SUMS.txt.sig
/// （和 App 用同一把 Ed25519 发布密钥签名，scripts/release_firmware.sh 生成）。
public enum FirmwareFeed {
    public static let tagPrefix = "firmware-v"
    public static let releasesURL =
        URL(string: "https://api.github.com/repos/\(UpdateCore.owner)/\(UpdateCore.repo)/releases?per_page=50")!

    public static func assetName(version: String) -> String { "NotiBridge-ESP32-\(version).bin" }

    public struct Firmware: Equatable {
        public let version: String
        public let image: UpdateCore.Asset
        public let sums: UpdateCore.Asset
        public let signature: UpdateCore.Asset
        public let notes: String
    }

    /// 从 releases 列表里找最新的固件（跳过草稿、预发布和缺文件的）
    public static func latest(fromReleasesJSON data: Data) throws -> Firmware? {
        let releases = try JSONDecoder().decode([UpdateCore.Release].self, from: data)
        var best: Firmware?
        for r in releases where !r.draft && !r.prerelease && r.tagName.hasPrefix(tagPrefix) {
            let v = String(r.tagName.dropFirst(tagPrefix.count))
            guard UpdateCore.parseVersion(v) != nil,
                  let img = r.asset(named: assetName(version: v)),
                  let sums = r.asset(named: UpdateCore.sumsAssetName),
                  let sig = r.asset(named: UpdateCore.sumsSignatureAssetName) else { continue }
            if let b = best, !UpdateCore.isNewer(v, than: b.version) { continue }
            best = Firmware(version: v, image: img, sums: sums, signature: sig, notes: r.body ?? "")
        }
        return best
    }

    public enum VerifyError: Error, CustomStringConvertible {
        case badSignature, missingHash, hashMismatch
        public var description: String {
            switch self {
            case .badSignature: return "固件签名校验失败（文件可能被篡改）"
            case .missingHash: return "校验文件里没有这个固件"
            case .hashMismatch: return "固件文件校验不一致，请重新下载"
            }
        }
    }

    /// 校验签名和哈希，通过后才能刷写
    public static func verify(image: Data, version: String, sums: Data, signature: Data,
                              publicKeyBase64: String = UpdateCore.releasePublicKeyBase64) throws {
        guard UpdateCore.verifySumsSignature(sums: sums, signatureFile: signature, publicKeyBase64: publicKeyBase64) else {
            throw VerifyError.badSignature
        }
        guard let want = UpdateCore.parseSha256Sums(String(decoding: sums, as: UTF8.self))[assetName(version: version)] else {
            throw VerifyError.missingHash
        }
        let got = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw VerifyError.hashMismatch }
    }
}
