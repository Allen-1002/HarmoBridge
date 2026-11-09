import Foundation
import XCTest
@testable import NotiBridgeCore

final class UpdateCoreTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertEqual(UpdateCore.compareVersions("1.3.0", "1.2.3"), 1)
        XCTAssertEqual(UpdateCore.compareVersions("v1.3.0", "1.3.0"), 0)
        XCTAssertEqual(UpdateCore.compareVersions("1.3", "1.3.0"), 0)
        XCTAssertEqual(UpdateCore.compareVersions("1.10.0", "1.9.9"), 1)
        XCTAssertEqual(UpdateCore.compareVersions("1.2.9", "1.10.0"), -1)
        XCTAssertEqual(UpdateCore.compareVersions("2.0.0", "1.99.99"), 1)
        XCTAssertEqual(UpdateCore.compareVersions("1.3.0-beta", "1.3.0"), 0)
        XCTAssertNil(UpdateCore.compareVersions("abc", "1.0.0"))
        XCTAssertNil(UpdateCore.compareVersions("1..0", "1.0.0"))
        XCTAssertTrue(UpdateCore.isNewer("v1.3.1", than: "1.3.0"))
        XCTAssertFalse(UpdateCore.isNewer("v1.3.0", than: "1.3.0"))
        XCTAssertFalse(UpdateCore.isNewer("garbage", than: "1.3.0"))
        XCTAssertEqual(UpdateCore.versionString(fromTag: "v1.3.0"), "1.3.0")
    }

    func testParseSha256Sums() {
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "B", count: 64)
        let text = """
        \(a)  NotiBridge-1.3.0-macOS.dmg
        \(b) *NotiBridge-1.3.0-Windows-x64.zip

        # comment
        nothex  bad.txt
        \(a)  ./dist/NotiBridge-1.3.0-HarmonyOS-unsigned.hap
        """
        let m = UpdateCore.parseSha256Sums(text)
        XCTAssertEqual(m["NotiBridge-1.3.0-macOS.dmg"], a)
        XCTAssertEqual(m["NotiBridge-1.3.0-Windows-x64.zip"], b.lowercased())
        XCTAssertEqual(m["NotiBridge-1.3.0-HarmonyOS-unsigned.hap"], a)
        XCTAssertNil(m["bad.txt"])
        XCTAssertEqual(m.count, 3)
    }

    func testDecodeRelease() throws {
        let json = """
        {"tag_name":"v1.3.0","name":"NotiBridge v1.3.0","html_url":"https://github.com/Allen-1002/NotiBridge/releases/tag/v1.3.0",
         "draft":false,"prerelease":false,"body":"简介\\n\\n## 下载\\n| a | b |\\n\\n## 更新内容\\n\\n- **自动更新**\\n- 版本统一\\n\\n## 已知限制\\n- x",
         "assets":[{"name":"NotiBridge-1.3.0-macOS.dmg","browser_download_url":"https://example.com/a.dmg","size":123}]}
        """
        let r = try UpdateCore.decodeRelease(Data(json.utf8))
        XCTAssertEqual(r.version, "1.3.0")
        XCTAssertEqual(r.asset(named: UpdateCore.macAssetName(version: r.version))?.size, 123)
        XCTAssertEqual(r.notesSnippet(), "简介\n• 自动更新\n• 版本统一")
    }

    /// 发布前检查：dist/ 里有本次发布文件时，用内置公钥验证真实签名，并确认下载前显示的说明第一行是安全提示
    func testRealReleaseArtifactsIfPresent() throws {
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist")
        let sums = dist.appendingPathComponent("SHA256SUMS.txt"), sig = dist.appendingPathComponent("SHA256SUMS.txt.sig")
        guard let s = try? Data(contentsOf: sums), let g = try? Data(contentsOf: sig) else {
            throw XCTSkip("dist/ 中没有发布文件")
        }
        XCTAssertTrue(UpdateCore.verifySumsSignature(sums: s, signatureFile: g))
        let notes = dist.appendingPathComponent("RELEASE_NOTES-1.1.0.md")
        if let body = try? String(contentsOf: notes, encoding: .utf8) {
            XCTAssertTrue(UpdateCore.notesSnippet(body).hasPrefix("安全更新：更新后所有手机都必须重新配对"))
        }
    }
}
