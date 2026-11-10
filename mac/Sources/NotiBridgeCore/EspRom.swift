import CryptoKit
import Foundation

/// ESP32 芯片内置 ROM 下载协议（esptool 用的同一套串口协议），用于在 App 里直接刷写固件，
/// 不需要用户安装 Python 或 esptool。只实现刷写需要的几条命令，不上传 stub。
/// 与 Windows 端 EspRom.cs 逻辑一致。
public enum EspSlip {
    public static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xC0]
        out.reserveCapacity(data.count + 8)
        for b in data {
            switch b {
            case 0xC0: out += [0xDB, 0xDC]
            case 0xDB: out += [0xDB, 0xDD]
            default: out.append(b)
            }
        }
        out.append(0xC0)
        return out
    }

    /// 流式解码：喂入任意字节，返回完整的帧。
    public struct Decoder {
        private var frame: [UInt8] = []
        private var inFrame = false
        private var escape = false
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
            var frames: [[UInt8]] = []
            for b in bytes {
                if b == 0xC0 {
                    if inFrame, !frame.isEmpty { frames.append(frame) }
                    // 0xC0 既是结束也是开始
                    frame = []
                    inFrame = true
                    escape = false
                    continue
                }
                guard inFrame else { continue }
                if escape {
                    escape = false
                    frame.append(b == 0xDC ? 0xC0 : b == 0xDD ? 0xDB : b)
                } else if b == 0xDB {
                    escape = true
                } else {
                    frame.append(b)
                }
            }
            return frames
        }
    }
}

public enum EspRomCommand: UInt8 {
    case flashBegin = 0x02
    case flashData = 0x03
    case flashEnd = 0x04
    case sync = 0x08
    case readReg = 0x0A
    case readFlashSlow = 0x0E
    case spiSetParams = 0x0B
    case spiAttach = 0x0D
    case changeBaudrate = 0x0F
    case spiFlashMd5 = 0x13
}

public struct EspRomResponse: Equatable {
    public var command: UInt8
    public var value: UInt32
    public var data: [UInt8]

    /// ESP32 ROM 的响应数据末尾是 4 字节状态：第 1 字节 0 为成功，第 2 字节是错误码。
    public var ok: Bool { data.count >= 4 && data[data.count - 4] == 0 }
    public var errorCode: UInt8 { data.count >= 4 ? data[data.count - 3] : 0xFF }
    public var payload: [UInt8] { data.count >= 4 ? Array(data[0..<(data.count - 4)]) : [] }

    public static func parse(_ frame: [UInt8]) -> EspRomResponse? {
        guard frame.count >= 8, frame[0] == 0x01 else { return nil }
        let size = Int(frame[2]) | Int(frame[3]) << 8
        guard frame.count >= 8 + size else { return nil }
        let value = UInt32(frame[4]) | UInt32(frame[5]) << 8 | UInt32(frame[6]) << 16 | UInt32(frame[7]) << 24
        return EspRomResponse(command: frame[1], value: value, data: Array(frame[8..<(8 + size)]))
    }
}

public enum EspRomPacket {
    public static let flashBlockSize = 0x400
    public static let syncPayload: [UInt8] = [0x07, 0x07, 0x12, 0x20] + [UInt8](repeating: 0x55, count: 32)

    public static func checksum(_ data: [UInt8]) -> UInt32 {
        UInt32(data.reduce(UInt8(0xEF)) { $0 ^ $1 })
    }

    public static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }

    public static func le32s(_ vs: UInt32...) -> [UInt8] { vs.flatMap(le32) }

    /// 请求包：方向 0x00、命令、数据长度、校验（只有 FLASH_DATA 用）、数据
    public static func request(_ cmd: EspRomCommand, _ data: [UInt8], checksum: UInt32 = 0) -> [UInt8] {
        let n = UInt16(data.count)
        return [0x00, cmd.rawValue, UInt8(n & 0xFF), UInt8(n >> 8)] + le32(checksum) + data
    }
}

/// 刷写用的串口。实现：Mac 的 POSIX 串口；测试里是模拟 ROM。
public protocol EspSerialTransport: AnyObject {
    func write(_ bytes: [UInt8]) throws
    /// 读取可用字节，最多等待 timeout 秒；超时返回空数组。
    func read(timeout: TimeInterval) throws -> [UInt8]
    func setDTR(_ on: Bool) throws
    func setRTS(_ on: Bool) throws
    func setBaud(_ baud: Int) throws
    func flushInput()
}

public enum EspFlashError: Error, CustomStringConvertible {
    case noSync
    case timeout(String)
    case romError(String, UInt8)
    case verifyFailed
    case badImage(String)

    public var description: String {
        switch self {
        case .noSync: return "无法进入下载模式。请按住板子上的 BOOT 键再点刷写，或换一根数据线。"
        case let .timeout(step): return "\(step) 超时，板子没有响应"
        case let .romError(step, code): return "\(step) 失败（错误码 0x\(String(code, radix: 16))）"
        case .verifyFailed: return "写入后校验不一致，请重试"
        case let .badImage(reason): return "固件文件无效：\(reason)"
        }
    }
}

/// 用 ROM 下载协议刷写一段连续的镜像。
public final class EspFlasher {
    public enum Stage: Equatable {
        case connecting
        /// 读取原固件做备份（0~1）
        case backingUp(Double)
        case erasing
        case writing(Double)
        case verifying
        case done
    }

    private let port: EspSerialTransport
    private var decoder = EspSlip.Decoder()
    private var pending: [[UInt8]] = []
    public var onStage: ((Stage) -> Void)?
    public var log: ((String) -> Void)?
    /// 测试时设为 0 加快速度
    public var resetDelay: TimeInterval = 0.1

    public init(port: EspSerialTransport) {
        self.port = port
    }

    /// 刷写镜像到 offset（合并镜像从 0x1000 开始），完成后复位运行新固件。
    public func flash(image: [UInt8], offset: UInt32, fastBaud: Int? = 460_800, flashSize: UInt32 = 4 << 20) throws {
        try begin(fastBaud: fastBaud, flashSize: flashSize)
        try write(image: image, offset: offset, flashSize: flashSize)
        try finish()
    }

    private(set) var flashSize: UInt32 = 4 << 20

    /// 进入下载模式、连接闪存、切换波特率。之后可以多次 read/write，最后 finish。
    public func begin(fastBaud: Int? = 460_800, flashSize: UInt32 = 4 << 20) throws {
        self.flashSize = flashSize
        onStage?(.connecting)
        try connect()
        _ = try command(.spiAttach, EspRomPacket.le32s(0, 0), step: "连接闪存")
        _ = try command(.spiSetParams, EspRomPacket.le32s(0, flashSize, 64 * 1024, 4096, 256, 0xFFFF),
                        step: "设置闪存参数")
        if let baud = fastBaud {
            _ = try command(.changeBaudrate, EspRomPacket.le32s(UInt32(baud), 0), step: "切换波特率")
            try port.setBaud(baud)
            Thread.sleep(forTimeInterval: resetDelay / 2)
            port.flushInput()
            decoder = EspSlip.Decoder()
            pending = []
        }
    }

    /// 读出芯片的出厂 MAC 地址（eFuse），用来区分不同的板子。
    public func readMac() throws -> String {
        let w1 = try command(.readReg, EspRomPacket.le32(0x3FF5_A004), step: "读取芯片地址").value
        let w2 = try command(.readReg, EspRomPacket.le32(0x3FF5_A008), step: "读取芯片地址").value
        let bytes = [UInt8(w2 >> 8 & 0xFF), UInt8(w2 & 0xFF), UInt8(w1 >> 24 & 0xFF), UInt8(w1 >> 16 & 0xFF),
                     UInt8(w1 >> 8 & 0xFF), UInt8(w1 & 0xFF)]
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// 读闪存（ROM 的慢速读取，每次 64 字节）。progress 为 0~1。
    public func read(offset: UInt32, length: Int, progress: ((Double) -> Void)? = nil) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var lastReport = 0
        while out.count < length {
            let n = min(64, length - out.count)
            let r = try command(.readFlashSlow, EspRomPacket.le32s(offset + UInt32(out.count), UInt32(n)),
                                step: "读取闪存", timeout: 2)
            let p = r.payload
            guard p.count >= n else { throw EspFlashError.romError("读取闪存", 0xFE) }
            out += p[0..<n]
            if out.count - lastReport >= 16384 || out.count == length {
                lastReport = out.count
                progress?(Double(out.count) / Double(length))
            }
        }
        return out
    }

    /// 擦除并写入一段镜像，写完用 MD5 校验。
    public func write(image: [UInt8], offset: UInt32, flashSize: UInt32? = nil) throws {
        guard !image.isEmpty else { throw EspFlashError.badImage("文件为空") }
        guard Int(offset) + image.count <= Int(flashSize ?? self.flashSize) else {
            throw EspFlashError.badImage("超过闪存大小")
        }
        let block = EspRomPacket.flashBlockSize
        let blocks = (image.count + block - 1) / block
        onStage?(.erasing)
        // 擦除时间与大小有关：每 MB 约 10 秒
        let eraseTimeout = max(10, Double(image.count) / 1_000_000 * 15)
        _ = try command(.flashBegin, EspRomPacket.le32s(UInt32(image.count), UInt32(blocks), UInt32(block), offset),
                        step: "擦除闪存", timeout: eraseTimeout)
        for seq in 0..<blocks {
            var chunk = Array(image[(seq * block)..<min(image.count, (seq + 1) * block)])
            if chunk.count < block { chunk += [UInt8](repeating: 0xFF, count: block - chunk.count) }
            let header = EspRomPacket.le32s(UInt32(chunk.count), UInt32(seq), 0, 0)
            _ = try command(.flashData, header + chunk, checksum: EspRomPacket.checksum(chunk),
                            step: "写入第 \(seq + 1) 块", timeout: 5)
            onStage?(.writing(Double(seq + 1) / Double(blocks)))
        }
        onStage?(.verifying)
        guard try md5(offset: offset, length: image.count) == Self.md5Hex(image) else { throw EspFlashError.verifyFailed }
    }

    public static func md5Hex(_ data: [UInt8]) -> String {
        Insecure.MD5.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
    }

    /// 闪存一段区域的 MD5（芯片内计算）
    public func md5(offset: UInt32, length: Int) throws -> String {
        let r = try command(.spiFlashMd5, EspRomPacket.le32s(offset, UInt32(length), 0, 0),
                            step: "校验", timeout: max(8, Double(length) / 1_000_000 * 10))
        let p = r.payload
        if p.count == 32 { return String(decoding: p, as: UTF8.self).lowercased() }
        if p.count == 16 { return p.map { String(format: "%02x", $0) }.joined() }
        throw EspFlashError.verifyFailed
    }

    /// 退出下载模式（参数 1 = 留在下载模式），再用 RTS 硬复位运行固件。
    public func finish() throws {
        _ = try? command(.flashEnd, EspRomPacket.le32(1), step: "结束", timeout: 2)
        try hardReset()
        onStage?(.done)
    }

    // MARK: - 复位与同步

    /// 经典自动下载电路：RTS 接 EN，DTR 接 IO0。
    func enterBootloader() throws {
        try port.setDTR(false)
        try port.setRTS(true) // EN 低：复位
        Thread.sleep(forTimeInterval: resetDelay)
        try port.setDTR(true) // IO0 低
        try port.setRTS(false) // EN 高：从下载模式启动
        Thread.sleep(forTimeInterval: resetDelay / 2)
        try port.setDTR(false)
    }

    public func hardReset() throws {
        try port.setDTR(false)
        try port.setRTS(true)
        Thread.sleep(forTimeInterval: resetDelay)
        try port.setRTS(false)
    }

    func connect() throws {
        for attempt in 0..<5 {
            try enterBootloader()
            port.flushInput()
            decoder = EspSlip.Decoder()
            pending = []
            for _ in 0..<4 {
                try port.write(EspSlip.encode(EspRomPacket.request(.sync, EspRomPacket.syncPayload)))
                if let r = try? waitResponse(for: .sync, timeout: 0.1), r.ok {
                    // ROM 对一次 SYNC 会回好几个响应，读掉
                    while (try? waitResponse(for: .sync, timeout: 0.1)) != nil {}
                    log?("已进入下载模式（第 \(attempt + 1) 次尝试）")
                    return
                }
            }
        }
        throw EspFlashError.noSync
    }

    // MARK: - 命令

    @discardableResult
    func command(_ cmd: EspRomCommand, _ data: [UInt8], checksum: UInt32 = 0, step: String,
                 timeout: TimeInterval = 3) throws -> EspRomResponse {
        try port.write(EspSlip.encode(EspRomPacket.request(cmd, data, checksum: checksum)))
        let r = try waitResponse(for: cmd, timeout: timeout, step: step)
        guard r.ok else { throw EspFlashError.romError(step, r.errorCode) }
        return r
    }

    private func waitResponse(for cmd: EspRomCommand, timeout: TimeInterval, step: String = "") throws -> EspRomResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while !pending.isEmpty {
                let f = pending.removeFirst()
                if let r = EspRomResponse.parse(f), r.command == cmd.rawValue { return r }
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw EspFlashError.timeout(step) }
            let bytes = try port.read(timeout: min(left, 0.05))
            if !bytes.isEmpty { pending += decoder.feed(bytes) }
        }
    }
}
