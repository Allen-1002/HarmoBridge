import Foundation

/// 串口上混合的文本行和二进制音频帧（docs/esp32-serial.md）。与 Windows 端 AudioLink.cs 一致。
/// 帧：0xFE 0xA5 类型(1) 长度(2, 小端) 序号(2, 小端) 数据；0xFE 不会出现在 UTF-8 文本里。
public enum SerialFrameType: UInt8 {
    /// 手机 → 电脑（扬声器）
    case audioDown = 0x01
    /// 电脑麦克风 → 手机
    case audioUp = 0x02
}

public struct SerialFrame: Equatable {
    public var type: UInt8
    public var seq: UInt16
    public var data: [UInt8]
}

public struct SerialDemux {
    public enum Item: Equatable {
        case line(String)
        case frame(SerialFrame)
    }

    private var line: [UInt8] = []
    private var state = 0 // 0 文本，1 收到 0xFE，2 帧头，3 数据
    private var header: [UInt8] = []
    private var payload: [UInt8] = []
    private var length = 0
    public static let maxFrame = 1024

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Item] {
        var out: [Item] = []
        for b in bytes {
            switch state {
            case 1:
                state = b == 0xA5 ? 2 : 0
                header.removeAll(keepingCapacity: true)
            case 2:
                header.append(b)
                if header.count == 5 {
                    length = Int(header[1]) | Int(header[2]) << 8
                    payload.removeAll(keepingCapacity: true)
                    state = length == 0 || length > Self.maxFrame ? 0 : 3
                }
            case 3:
                payload.append(b)
                if payload.count == length {
                    out.append(.frame(SerialFrame(type: header[0], seq: UInt16(header[3]) | UInt16(header[4]) << 8,
                                                  data: payload)))
                    state = 0
                }
            default:
                if b == 0xFE {
                    state = 1
                } else if b == 0x0A {
                    out.append(.line(String(decoding: line, as: UTF8.self)))
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(b)
                    if line.count > 16384 { line.removeAll() }
                }
            }
        }
        return out
    }

    public static func encode(type: SerialFrameType, seq: UInt16, data: [UInt8]) -> [UInt8] {
        let n = data.count
        return [0xFE, 0xA5, type.rawValue, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(seq & 0xFF), UInt8(seq >> 8)] + data
    }
}

/// 抖动缓冲：网络/串口到达不均匀，播放按固定节奏取。保持约 target 毫秒的余量；
/// 积压太多（两边时钟有偏差）时丢掉一点，不够时补静音，避免延迟越积越大或断断续续。
public final class JitterBuffer {
    public let sampleRate: Int
    private var samples: [Int16] = []
    private var head = 0
    private let lock = NSLock()
    private let target: Int
    private let high: Int
    private var primed = false
    public private(set) var underruns = 0
    public private(set) var dropped = 0

    public init(sampleRate: Int, targetMs: Int = 60, maxMs: Int = 160) {
        self.sampleRate = sampleRate
        target = sampleRate * targetMs / 1000
        high = sampleRate * maxMs / 1000
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count - head
    }

    public func push(_ s: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: s)
        // 积压超过上限：丢到目标余量（时钟漂移或系统卡顿后追上）
        let n = samples.count - head
        if n > high {
            let drop = n - target
            head += drop
            dropped += drop
        }
        if head > 32768 {
            samples.removeFirst(head)
            head = 0
        }
        if !primed && samples.count - head >= target { primed = true }
    }

    /// 取 n 个样本；不够时补 0（静音），并重新攒到目标余量再开始播放
    public func pull(_ n: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        guard primed else { return [Int16](repeating: 0, count: n) }
        let avail = samples.count - head
        if avail >= n {
            let out = Array(samples[head..<(head + n)])
            head += n
            return out
        }
        var out = Array(samples[head..<samples.count])
        head = samples.count
        out += [Int16](repeating: 0, count: n - out.count)
        underruns += 1
        primed = false
        return out
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
        head = 0
        primed = false
    }
}

public enum PCM16 {
    public static func samples(_ bytes: [UInt8]) -> [Int16] {
        var out = [Int16](repeating: 0, count: bytes.count / 2)
        for i in 0..<out.count { out[i] = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8) }
        return out
    }

    public static func bytes(_ s: [Int16]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: s.count * 2)
        for (i, v) in s.enumerated() {
            let u = UInt16(bitPattern: v)
            out[2 * i] = UInt8(u & 0xFF)
            out[2 * i + 1] = UInt8(u >> 8)
        }
        return out
    }
}
