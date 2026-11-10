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
        default:
            reply(cmd, status: 1, err: 0x05)
        }
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
        let line = #"@{"t":"notif","ev":"add","uid":4294967295,"flags":4,"cat":4,"app":"com.tencent.xin","appName":"微信","title":"张三","sub":"","msg":"晚上吃饭？\n\"好\"","date":"20261110T094500","pos":"","neg":"清除"}"#
        guard case let .notification(n)? = Esp32LinkParser.parse(line: line) else { return XCTFail() }
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

    func testParseOtherEventsAndLines() {
        XCTAssertEqual(Esp32LinkParser.parse(line: #"@{"t":"removed","uid":9}"#), .removed(uid: 9))
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
