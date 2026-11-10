import Darwin
import Foundation

/// macOS 串口（/dev/cu.*）。支持任意波特率（IOSSIOSPEED）与 DTR/RTS 控制，用于刷写和固件通信。
public final class PosixSerialPort: EspSerialTransport {
    public enum OpenError: Error, CustomStringConvertible {
        case open(String, Int32)
        public var description: String {
            switch self {
            case let .open(path, e):
                return e == EBUSY ? "串口 \(path) 被其他程序占用" : "无法打开串口 \(path)（\(String(cString: strerror(e)))）"
            }
        }
    }

    public let path: String
    private var fd: Int32

    /// IOSSIOSPEED = _IOW('T', 2, speed_t)
    private static let iossiospeed: UInt = 0x8008_5402

    public init(path: String, baud: Int = 115_200) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw OpenError.open(path, errno) }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // 关闭时不要拉低 DTR（会让一些板子复位）
        t.c_cflag &= ~tcflag_t(HUPCL)
        t.c_cc.16 = 0 // VMIN
        t.c_cc.17 = 0 // VTIME
        tcsetattr(fd, TCSANOW, &t)
        try setBaud(baud)
    }

    deinit { close() }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    public func setBaud(_ baud: Int) throws {
        var speed = speed_t(baud)
        if ioctl(fd, Self.iossiospeed, &speed) != 0 {
            var t = termios()
            tcgetattr(fd, &t)
            cfsetspeed(&t, speed)
            tcsetattr(fd, TCSANOW, &t)
        }
    }

    private func modem(_ bit: Int32, _ on: Bool) throws {
        var b = bit
        _ = ioctl(fd, on ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &b)
    }

    public func setDTR(_ on: Bool) throws { try modem(TIOCM_DTR, on) }
    public func setRTS(_ on: Bool) throws { try modem(TIOCM_RTS, on) }

    public func flushInput() { tcflush(fd, TCIFLUSH) }

    public func write(_ bytes: [UInt8]) throws {
        var off = 0
        let deadline = Date().addingTimeInterval(5)
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                off += n
            } else if n < 0 && errno != EAGAIN {
                throw OpenError.open(path, errno)
            } else {
                if Date() > deadline { throw EspFlashError.timeout("写串口") }
                usleep(1000)
            }
        }
    }

    public func read(timeout: TimeInterval) throws -> [UInt8] {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, Int32(max(0, timeout * 1000)))
        if r < 0 && errno != EINTR { throw OpenError.open(path, errno) }
        guard r > 0 else { return [] }
        if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & Int16(POLLIN) == 0 {
            throw OpenError.open(path, ENXIO) // 板子被拔掉
        }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        if n < 0 {
            if errno == EAGAIN { return [] }
            throw OpenError.open(path, errno)
        }
        return Array(buf[0..<n])
    }
}
