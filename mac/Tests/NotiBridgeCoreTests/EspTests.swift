import CryptoKit
import Foundation
@testable import NotiBridgeCore
import XCTest

/// 模拟 ESP32 ROM：只有经过正确的 RTS/DTR 复位序列才进入下载模式，按协议处理命令并把数据写进“闪存”。
final class FakeRom: EspSerialTransport {
    var flash = [UInt8](repeating: 0xFF, count: 4 << 20)
    var dtr = false, rts = false
    var inBootloader = false
    var baud = 115_200
    var output: [UInt8] = []
    var decoder = EspSlip.Decoder()
    var corruptBlock: Int?
    var syncIgnoredTimes = 0
    var resets = 0
    var readCount = 0
    private var writeOffset = 0
    private var blockSize = 0
    private var expectedSeq = 0
    private var resetPhase = 0

    func setDTR(_ on: Bool) throws {
        dtr = on
        // EN 从低变高时 IO0 为低：进入下载模式
        if resetPhase == 1 && on && rts { resetPhase = 2 }
    }

    func setRTS(_ on: Bool) throws {
        if on && !dtr { resetPhase = 1; inBootloader = false; resets += 1 }
        if !on && rts {
            inBootloader = resetPhase == 2 && dtr
            resetPhase = 0
        }
        rts = on
    }

    func setBaud(_ b: Int) throws { baud = b }
    func flushInput() { output.removeAll() }

    func read(timeout: TimeInterval) throws -> [UInt8] {
        defer { output.removeAll() }
        return output
    }

    func write(_ bytes: [UInt8]) throws {
        for frame in decoder.feed(bytes) { handle(frame) }
    }

    private func reply(_ cmd: UInt8, _ data: [UInt8] = [], status: UInt8 = 0, err: UInt8 = 0) {
        let body = data + [status, err, 0, 0]
        let n = UInt16(body.count)
        output += EspSlip.encode([0x01, cmd, UInt8(n & 0xFF), UInt8(n >> 8), 0, 0, 0, 0] + body)
    }

    private func u32(_ d: [UInt8], _ i: Int) -> Int {
        Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
    }

    private func handle(_ f: [UInt8]) {
        guard inBootloader, f.count >= 8, f[0] == 0 else { return }
        let cmd = f[1]
        let data = Array(f[8...])
        switch cmd {
        case 0x08:
            if syncIgnoredTimes > 0 { syncIgnoredTimes -= 1; return }
            XCTAssertEqual(data, EspRomPacket.syncPayload)
            for _ in 0..<3 { reply(cmd) }
        case 0x0D, 0x0B:
            reply(cmd)
        case 0x0F:
            reply(cmd)
            baud = u32(data, 0)
        case 0x02:
            let size = u32(data, 0), off = u32(data, 12)
            blockSize = u32(data, 8)
            writeOffset = off
            expectedSeq = 0
            for i in off..<(off + size) { flash[i] = 0xFF }
            reply(cmd)
        case 0x03:
            let len = u32(data, 0), seq = u32(data, 4)
            let payload = Array(data[16..<(16 + len)])
            let ck = UInt32(f[4]) | UInt32(f[5]) << 8
            guard seq == expectedSeq, ck == EspRomPacket.checksum(payload), len == blockSize else {
                reply(cmd, status: 1, err: 0x07)
                return
            }
            var p = payload
            if seq == corruptBlock { p[0] ^= 0xFF }
            for (i, b) in p.enumerated() { flash[writeOffset + seq * blockSize + i] = b }
            expectedSeq += 1
            reply(cmd)
        case 0x13:
            let off = u32(data, 0), size = u32(data, 4)
            let hex = Insecure.MD5.hash(data: Data(flash[off..<(off + size)])).map { String(format: "%02x", $0) }.joined()
            reply(cmd, Array(hex.utf8))
        case 0x04:
            reply(cmd)
        case 0x0A:
            // eFuse MAC：1c:8f:57:16:d3:44
            let addr = u32(data, 0)
            let v: UInt32 = addr == 0x3FF5_A004 ? 0x5716_D344 : addr == 0x3FF5_A008 ? 0x0000_1C8F : 0
            let n = UInt16(4)
            output += EspSlip.encode([0x01, cmd, UInt8(n), 0] + EspRomPacket.le32(v) + [0, 0, 0, 0])
        case 0x0E:
            let off = u32(data, 0), len = u32(data, 4)
            readCount += 1
            reply(cmd, Array(flash[off..<(off + len)]))
        default:
            reply(cmd, status: 1, err: 0x05)
        }
    }
}

final class EspBackupTests: XCTestCase {
    private func tempStore() -> EspBackupStore {
        EspBackupStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("esp-backup-\(UUID().uuidString)"))
    }

    /// 把一段字节写成假的应用镜像头（esp_app_desc_t 的 project_name）
    private func fakeApp(_ rom: FakeRom, name: String) {
        let base = 0x10020
        rom.flash.replaceSubrange(base..<(base + 4), with: EspRomPacket.le32(0xABCD_5432))
        var n = Array(name.utf8) + [UInt8](repeating: 0, count: 32 - name.utf8.count)
        n = Array(n.prefix(32))
        rom.flash.replaceSubrange((base + 0x30)..<(base + 0x50), with: n)
    }

    func testBackupFlashAgainAndRestore() throws {
        let rom = FakeRom()
        // 原固件：bootloader、应用、远处的数据分区
        for i in 0x1000..<0x6000 { rom.flash[i] = UInt8(i & 0x7F) }
        fakeApp(rom, name: "factory_demo")
        for i in 0x300000..<0x300100 { rom.flash[i] = 0x42 }
        let original = rom.flash
        let store = tempStore()
        let fw1 = [UInt8](repeating: 0x11, count: 0x20000)

        XCTAssertEqual(try EspFirmwareInstaller.install(image: fw1, port: rom, store: store, resetDelay: 0), .created)
        // 只读了非空的块（3 块 × 64KB / 64 字节），不是整个 4MB
        XCTAssertLessThan(rom.readCount, 3 * 1024 + 10)
        XCTAssertEqual(Array(rom.flash[0x1000..<0x21000]), fw1)
        let info = try XCTUnwrap(store.info(mac: "1c:8f:57:16:d3:44"))
        XCTAssertEqual(info.touchedEnd, 0x21000)
        XCTAssertFalse(info.wasBlank)

        // 再刷一个更大的版本：不重新备份，记录更远的写入位置
        fakeApp(rom, name: "notibridge_esp32")
        let fw2 = [UInt8](repeating: 0x22, count: 0x40000)
        XCTAssertEqual(try EspFirmwareInstaller.install(image: fw2, port: rom, store: store, resetDelay: 0), .kept)
        XCTAssertEqual(store.info(mac: "1c:8f:57:16:d3:44")?.touchedEnd, 0x41000)

        // 模拟固件运行时写了 NVS（iPhone 配对）；更新固件时要保留
        for i in 0x9000..<0x9100 { rom.flash[i] = 0x99 }
        fakeApp(rom, name: "notibridge_esp32")
        let fw3 = [UInt8](repeating: 0x33, count: 0x40000)
        XCTAssertEqual(try EspFirmwareInstaller.install(image: fw3, port: rom, store: store, resetDelay: 0), .kept)
        XCTAssertEqual(rom.flash[0x9000], 0x99)
        XCTAssertEqual(rom.flash[0x8FFF], 0x33)
        XCTAssertEqual(rom.flash[0x10000], 0x33)
        _ = try EspFirmwareInstaller.restore(port: rom, store: store, resetDelay: 0)
        XCTAssertEqual(rom.flash, original)
        XCTAssertFalse(rom.inBootloader)
    }

    func testNoBackupWhenAlreadyNotiBridge() throws {
        let rom = FakeRom()
        fakeApp(rom, name: "notibridge_esp32")
        let store = tempStore()
        XCTAssertEqual(try EspFirmwareInstaller.install(image: [1, 2, 3], port: rom, store: store, resetDelay: 0),
                       .alreadyNotiBridge)
        XCTAssertNil(store.info(mac: "1c:8f:57:16:d3:44"))
        XCTAssertThrowsError(try EspFirmwareInstaller.restore(port: rom, store: store, resetDelay: 0))
    }

    func testBlankBoardAndCorruptBackup() throws {
        let rom = FakeRom()
        let store = tempStore()
        XCTAssertEqual(try EspFirmwareInstaller.install(image: [1, 2, 3], port: rom, store: store, resetDelay: 0), .created)
        XCTAssertEqual(store.info(mac: "1c:8f:57:16:d3:44")?.wasBlank, true)
        XCTAssertEqual(rom.readCount, 2) // 只读了应用描述，空块都跳过
        // 备份被改动后拒绝还原
        let url = store.imageURL(mac: "1c:8f:57:16:d3:44")
        var data = try Data(contentsOf: url)
        data[10] ^= 1
        try data.write(to: url)
        XCTAssertThrowsError(try EspFirmwareInstaller.restore(port: rom, store: store, resetDelay: 0))
        XCTAssertEqual(store.all().count, 1)
    }
}

final class EspTests: XCTestCase {
    func testSlipRoundTrip() {
        let data: [UInt8] = [0x01, 0xC0, 0xDB, 0x02, 0xDB, 0xDC]
        let enc = EspSlip.encode(data)
        XCTAssertEqual(enc, [0xC0, 0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0x02, 0xDB, 0xDD, 0xDC, 0xC0])
        var d = EspSlip.Decoder()
        // 前面有启动日志等杂讯，分片喂入
        var frames = d.feed(Array("ets Jun  8 2016\r\n".utf8) + Array(enc[0..<4]))
        frames += d.feed(Array(enc[4...]) + enc)
        XCTAssertEqual(frames, [data, data])
    }

    func testChecksumAndPacket() {
        XCTAssertEqual(EspRomPacket.checksum([]), 0xEF)
        XCTAssertEqual(EspRomPacket.checksum([0xEF]), 0)
        let p = EspRomPacket.request(.flashData, [1, 2, 3], checksum: 0x1234)
        XCTAssertEqual(p, [0x00, 0x03, 3, 0, 0x34, 0x12, 0, 0, 1, 2, 3])
    }

    private func image(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / 251) } }

    func testFlashWritesImageAndResets() throws {
        let rom = FakeRom()
        rom.syncIgnoredTimes = 6 // 前几次同步没有回应（模拟启动中）
        let img = image(5000)
        let f = EspFlasher(port: rom)
        f.resetDelay = 0
        var stages: [EspFlasher.Stage] = []
        f.onStage = { stages.append($0) }
        try f.flash(image: img, offset: 0x1000)
        XCTAssertEqual(Array(rom.flash[0x1000..<(0x1000 + img.count)]), img)
        XCTAssertEqual(rom.flash[0x1000 + img.count], 0xFF) // 末块补 0xFF
        XCTAssertEqual(rom.baud, 460_800)
        XCTAssertFalse(rom.inBootloader) // 已复位运行固件
        XCTAssertEqual(stages.first, .connecting)
        XCTAssertEqual(stages.last, .done)
        XCTAssertTrue(stages.contains(.writing(1)))
    }

    func testVerifyFailureIsReported() {
        let rom = FakeRom()
        rom.corruptBlock = 2
        let f = EspFlasher(port: rom)
        f.resetDelay = 0
        XCTAssertThrowsError(try f.flash(image: image(4096), offset: 0x1000, fastBaud: nil)) { e in
            guard case EspFlashError.verifyFailed = e else { return XCTFail("\(e)") }
        }
    }

    func testNoSyncWhenBoardNeverEntersBootloader() {
        let rom = FakeRom()
        rom.syncIgnoredTimes = .max
        let f = EspFlasher(port: rom)
        f.resetDelay = 0
        XCTAssertThrowsError(try f.flash(image: image(10), offset: 0x1000)) { e in
            guard case EspFlashError.noSync = e else { return XCTFail("\(e)") }
        }
    }

    func testRejectsOversizeImage() {
        let f = EspFlasher(port: FakeRom())
        XCTAssertThrowsError(try f.flash(image: [1], offset: 4 << 20))
        XCTAssertThrowsError(try f.flash(image: [], offset: 0x1000))
    }

    // MARK: - 串口事件

    func testParseHelloAndState() {
        XCTAssertEqual(Esp32LinkParser.parse(line: "HB-ESP32 1.2.0 chip=esp32 ble=aa:bb:cc:dd:ee:ff proto=1\r"),
                       .hello(version: "1.2.0", bleAddress: "aa:bb:cc:dd:ee:ff", proto: 1))
        XCTAssertEqual(
            Esp32LinkParser.parse(line: #"@{"t":"state","ble":"ready","peer":"11:22:33:44:55:66","bonds":1,"pairing":false}"#),
            .state(Esp32LinkState(ble: "ready", peer: "11:22:33:44:55:66", bonds: 1, pairing: false)))
        XCTAssertNil(Esp32LinkParser.parse(line: "W (123) nb: something"))
        XCTAssertNil(Esp32LinkParser.parse(line: "@{broken"))
        XCTAssertNil(Esp32LinkParser.parse(line: #"@{"t":"notif","uid":-1}"#))
    }

    func testParseNotification() throws {
        let line = #"@{"t":"notif","ev":"add","uid":4294967295,"flags":4,"cat":4,"app":"com.tencent.xin","appName":"微信","title":"张三","sub":"","msg":"晚上吃饭？\n\"好\"","date":"20261110T094500","pos":"","neg":"清除","peer":"51:a8:27:cd:73:e0"}"#
        guard case let .notification(n)? = Esp32LinkParser.parse(line: line) else { return XCTFail() }
        XCTAssertEqual(n.peer, "51:a8:27:cd:73:e0")
        XCTAssertEqual(n.uid, 4_294_967_295)
        XCTAssertTrue(n.preExisting)
        XCTAssertFalse(n.modified)
        XCTAssertEqual(n.message, "晚上吃饭？\n\"好\"")
        let m = n.mirrored()
        XCTAssertEqual(m.id, "ios-4294967295")
        XCTAssertEqual(m.appName, "微信")
        XCTAssertEqual(m.bundleName, "com.tencent.xin")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: m.time)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 10, 9, 45])

        var withSub = n
        withSub.subtitle = "群聊"
        XCTAssertEqual(withSub.mirrored().text, "群聊\n晚上吃饭？\n\"好\"")
        withSub.appName = ""
        XCTAssertEqual(withSub.mirrored().appName, "com.tencent.xin")
    }

    func testParseBonds() {
        let line = #"@{"t":"bonds","list":[{"addr":"51:a8:27:cd:73:e0","name":"Allen 的 iPhone","connected":true,"ready":true},{"addr":"11:22:33:44:55:66","name":"","connected":false,"ready":false},{"name":"x"}]}"#
        XCTAssertEqual(Esp32LinkParser.parse(line: line), .bonds([
            PairedIphone(id: "51:a8:27:cd:73:e0", name: "Allen 的 iPhone", connected: true, ancsReady: true),
            PairedIphone(id: "11:22:33:44:55:66", name: "", connected: false, ancsReady: false),
        ]))
        XCTAssertEqual(Esp32LinkParser.parse(line: #"@{"t":"bonds","list":[]}"#), .bonds([]))
    }

    func testParseOtherEventsAndLines() {
        XCTAssertEqual(Esp32LinkParser.parse(line: #"@{"t":"removed","uid":9}"#), .removed(uid: 9, peer: ""))
        XCTAssertEqual(Esp32LinkParser.parse(line: #"@{"t":"removed","uid":9,"peer":"51:a8:27:cd:73:e0"}"#),
                       .removed(uid: 9, peer: "51:a8:27:cd:73:e0"))
        XCTAssertEqual(Esp32LinkParser.parse(line: #"@{"t":"acted","uid":9,"action":1}"#), .acted(uid: 9, action: 1))
        XCTAssertEqual(Esp32LinkParser.parse(line: #"@{"t":"err","code":"auth","msg":"x"}"#),
                       .error(code: "auth", message: "x"))
        var s = LineSplitter()
        XCTAssertEqual(s.feed(Array("ab\nc".utf8)), ["ab"])
        XCTAssertEqual(s.feed(Array("中\n".utf8)), ["c中"])
    }
}

/// 真板测试（默认跳过）：HB_ESP_PORT=/dev/cu.xxx HB_ESP_IMAGE=镜像 HB_ESP_OFFSET=0x1000 swift test --filter RealBoard
final class RealBoardFlashTests: XCTestCase {
    func testFlashRealBoard() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["HB_ESP_PORT"], let imagePath = env["HB_ESP_IMAGE"] else {
            throw XCTSkip("未设置 HB_ESP_PORT / HB_ESP_IMAGE")
        }
        let offset = UInt32((env["HB_ESP_OFFSET"] ?? "0x1000").dropFirst(2), radix: 16) ?? 0x1000
        let image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: imagePath)))
        let port = try PosixSerialPort(path: path)
        let f = EspFlasher(port: port)
        var last = -1
        f.onStage = { s in
            if case let .writing(p) = s { let pct = Int(p * 10); if pct != last { last = pct; print("写入 \(pct * 10)%") } }
            else { print("阶段 \(s)") }
        }
        f.log = { print($0) }
        let t = Date()
        try f.flash(image: image, offset: offset)
        print("完成，用时 \(String(format: "%.1f", Date().timeIntervalSince(t))) 秒")
    }
}

final class OtpExtractorTests: XCTestCase {
    func testExtract() {
        XCTAssertEqual(OtpExtractor.extract(title: "", text: "【某服务】您的验证码是 482913，5 分钟内有效"), "482913")
        XCTAssertEqual(OtpExtractor.extract(title: "Your code", text: "Use 7731 to sign in. Order 20261110"), "7731")
        XCTAssertEqual(OtpExtractor.extract(title: "张三", text: "明天 1530 见"), "")
        XCTAssertEqual(OtpExtractor.extract(title: "", text: "验证码 123"), "")
        XCTAssertTrue(OtpExtractor.isFinance(bundleName: "com.icbc.iphoneclient", title: "", text: ""))
        XCTAssertTrue(OtpExtractor.isFinance(bundleName: "x", title: "", text: "您的银行卡"))
        XCTAssertFalse(OtpExtractor.isFinance(bundleName: "com.apple.MobileSMS", title: "", text: "验证码 1234"))
    }
}

/// 真板读取速度（默认跳过）：HB_ESP_PORT=/dev/cu.xxx swift test --filter RealBoardRead
final class RealBoardReadTests: XCTestCase {
    func testReadSpeed() throws {
        guard let path = ProcessInfo.processInfo.environment["HB_ESP_PORT"] else { throw XCTSkip("未设置 HB_ESP_PORT") }
        let port = try PosixSerialPort(path: path)
        let f = EspFlasher(port: port)
        try f.begin()
        print("MAC \(try f.readMac())")
        let t = Date()
        let data = try f.read(offset: 0x1000, length: 64 * 1024)
        let secs = Date().timeIntervalSince(t)
        print("读取 64KB 用时 \(String(format: "%.2f", secs)) 秒")
        XCTAssertEqual(EspFlasher.md5Hex(data), try f.md5(offset: 0x1000, length: data.count))
        try f.finish()
    }
}

/// 真板备份/还原（默认跳过）：HB_ESP_PORT HB_ESP_STORE=目录 HB_ESP_ACTION=install|restore [HB_ESP_IMAGE]
final class RealBoardBackupTests: XCTestCase {
    func testBackupAction() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["HB_ESP_PORT"], let dir = env["HB_ESP_STORE"], let action = env["HB_ESP_ACTION"] else {
            throw XCTSkip("未设置 HB_ESP_PORT / HB_ESP_STORE / HB_ESP_ACTION")
        }
        let store = EspBackupStore(directory: URL(fileURLWithPath: dir))
        let port = try PosixSerialPort(path: path)
        var last = ""
        let onStage: (EspFlasher.Stage) -> Void = { s in
            let d: String
            switch s {
            case let .backingUp(p): d = "备份 \(Int(p * 10) * 10)%"
            case let .writing(p): d = "写入 \(Int(p * 10) * 10)%"
            default: d = "\(s)"
            }
            if d != last { last = d; print(d) }
        }
        let t = Date()
        if action == "install" {
            let image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: env["HB_ESP_IMAGE"]!)))
            print("结果 \(try EspFirmwareInstaller.install(image: image, port: port, store: store, onStage: onStage))")
        } else {
            print("还原 \(try EspFirmwareInstaller.restore(port: port, store: store, onStage: onStage))")
        }
        print("用时 \(String(format: "%.1f", Date().timeIntervalSince(t))) 秒")
    }
}

final class FirmwareFeedTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, pre: Bool = false, files: [String]) -> String {
        let assets = files.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)","size":10}"# }
        return #"{"tag_name":"\#(tag)","name":"x","html_url":"https://example.com","body":"说明","draft":\#(draft),"prerelease":\#(pre),"assets":[\#(assets.joined(separator: ","))]}"#
    }

    func testPicksNewestCompleteFirmwareRelease() throws {
        let full = { (v: String) in ["NotiBridge-ESP32-\(v).bin", "SHA256SUMS.txt", "SHA256SUMS.txt.sig"] }
        let json = "[" + [
            release("v1.3.0", files: ["NotiBridge-1.3.0-macOS.dmg", "SHA256SUMS.txt", "SHA256SUMS.txt.sig"]),
            release("firmware-v1.2.9", draft: true, files: full("1.2.9")),
            release("firmware-v1.2.8", pre: true, files: full("1.2.8")),
            release("firmware-v1.2.7", files: ["NotiBridge-ESP32-1.2.7.bin"]),
            release("firmware-v1.2.2", files: full("1.2.2")),
            release("firmware-v1.2.10", files: full("1.2.10")),
        ].joined(separator: ",") + "]"
        let fw = try XCTUnwrap(FirmwareFeed.latest(fromReleasesJSON: Data(json.utf8)))
        XCTAssertEqual(fw.version, "1.2.10")
        XCTAssertEqual(fw.image.name, "NotiBridge-ESP32-1.2.10.bin")
        XCTAssertNil(try FirmwareFeed.latest(fromReleasesJSON: Data("[]".utf8)))
    }

    func testVerify() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let image = Data([1, 2, 3])
        let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let sums = Data("\(hash)  NotiBridge-ESP32-1.2.2.bin\n".utf8)
        let sig = Data(try key.signature(for: sums).base64EncodedString().utf8)
        XCTAssertNoThrow(try FirmwareFeed.verify(image: image, version: "1.2.2", sums: sums, signature: sig, publicKeyBase64: pub))
        XCTAssertThrowsError(try FirmwareFeed.verify(image: Data([9]), version: "1.2.2", sums: sums, signature: sig, publicKeyBase64: pub))
        XCTAssertThrowsError(try FirmwareFeed.verify(image: image, version: "1.2.3", sums: sums, signature: sig, publicKeyBase64: pub))
        XCTAssertThrowsError(try FirmwareFeed.verify(image: image, version: "1.2.2", sums: sums, signature: sig))
    }
}

/// 联网检查真实固件 Release（默认跳过）：HB_FIRMWARE_FEED=1 swift test --filter RealFirmwareFeed
final class RealFirmwareFeedTests: XCTestCase {
    func testDownloadAndVerifyLatestFirmware() async throws {
        guard ProcessInfo.processInfo.environment["HB_FIRMWARE_FEED"] != nil else { throw XCTSkip("未设置 HB_FIRMWARE_FEED") }
        var req = URLRequest(url: FirmwareFeed.releasesURL)
        req.setValue(UpdateCore.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let fw = try XCTUnwrap(FirmwareFeed.latest(fromReleasesJSON: data))
        let img = try await URLSession.shared.data(from: fw.image.browserDownloadURL).0
        let sums = try await URLSession.shared.data(from: fw.sums.browserDownloadURL).0
        let sig = try await URLSession.shared.data(from: fw.signature.browserDownloadURL).0
        try FirmwareFeed.verify(image: img, version: fw.version, sums: sums, signature: sig)
        print("固件 \(fw.version) \(img.count) 字节，签名校验通过")
    }
}

final class UsbSerialChipTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(UsbSerialChip.name(vendorId: 0x1A86, productId: 0x7522), "CH340")
        XCTAssertEqual(UsbSerialChip.name(vendorId: 0x1A86, productId: 0x55D4), "CH9102")
        XCTAssertNil(UsbSerialChip.name(vendorId: 0x1A86, productId: 0x8091)) // 沁恒的 USB 集线器
        XCTAssertEqual(UsbSerialChip.name(vendorId: 0x10C4, productId: 0xEA60), "CP210x")
        XCTAssertNil(UsbSerialChip.name(vendorId: nil, productId: nil))
        let m = UsbSerialChip.driverMissingMessage(chips: ["CH340", "CH340"])
        XCTAssertTrue(m.contains("（CH340）") && m.contains("驱动"))
        XCTAssertFalse(m.contains("http"))
    }
}
