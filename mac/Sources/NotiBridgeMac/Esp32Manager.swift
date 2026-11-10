import Foundation
import IOKit
import IOKit.serial
import NotiBridgeCore

/// 使用方式：纯软件，或使用 ESP32 模块（额外支持在电脑上接打电话）。与手机端、Windows 端一致。
enum UseMode: String, CaseIterable, Identifiable {
    case software
    case esp32

    var id: String { rawValue }
    var title: String { self == .software ? "纯软件（推荐）" : "使用 ESP32" }
    var detail: String {
        self == .software
            ? "同步通知、验证码自动复制，不需要任何额外硬件。不能接打电话。"
            : "需要一块 ESP32 模块插在 Mac 的 USB 上，由 NotiBridge 刷写固件。iPhone 通过蓝牙把通知交给 ESP32，再转到 Mac；以后还会支持在 Mac 上接打电话（开发中）。"
    }
}

/// 一个可能是 ESP32 的 USB 串口。
struct Esp32Port: Identifiable, Hashable {
    let path: String // /dev/cu.xxx
    let name: String
    let vendorId: Int?
    let productId: Int?
    var id: String { path }

    /// 常见 ESP32 开发板的 USB 转串口芯片
    var chip: String? {
        switch vendorId {
        case 0x10C4: return "CP210x"
        case 0x1A86: return productId == 0x55D4 ? "CH9102" : "CH340"
        case 0x0403: return "FTDI"
        case 0x303A: return "ESP32 原生 USB"
        default: return nil
        }
    }

    var isLikelyEsp32: Bool { chip != nil }
    var label: String { chip.map { "\(name)（\($0)）" } ?? name }
}

/// ESP32 模块：检测硬件、检测/刷写固件，并与固件保持串口连接（接收 iPhone 通知）。
/// 固件握手：以 115200 波特率发送 "HB?\n"，NotiBridge 固件回复 "HB-ESP32 <版本> ..."。
/// 串口协议见 docs/esp32-serial.md。
@MainActor
final class Esp32Manager: ObservableObject {
    enum FirmwareState: Equatable {
        case unknown
        case checking
        case found(version: String)
        case missing(String)
        case flashing(String, Double)
        case flashFailed(String)
    }

    @Published var mode: UseMode = UseMode(rawValue: UserDefaults.standard.string(forKey: "useMode") ?? "") ?? .software {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "useMode")
            if mode == .esp32 { startLinkIfPossible() } else { stopLink() }
        }
    }
    @Published var ports: [Esp32Port] = []
    @Published var selected: String = UserDefaults.standard.string(forKey: "esp32Port") ?? "" {
        didSet { UserDefaults.standard.set(selected, forKey: "esp32Port") }
    }
    @Published var firmware: FirmwareState = .unknown
    @Published var scanned = false
    @Published var message = ""
    /// 与固件的连接（nil 表示未连接）
    @Published var link: Esp32LinkState?
    @Published var linkError = ""

    /// 收到固件事件（AppModel 处理通知）
    var onEvent: ((Esp32Event) -> Void)?
    var onLog: ((String) -> Void)?

    /// 随 App 打包的固件（build_app.sh 从 firmware/esp32/prebuilt 复制）
    static var firmwareURL: URL? { Bundle.main.url(forResource: "notibridge-esp32", withExtension: "bin") }
    static var firmwareAvailable: Bool { firmwareURL != nil }
    /// 合并镜像（bootloader + 分区表 + 应用）从 0x1000 开始
    static let firmwareOffset: UInt32 = 0x1000
    static var bundledVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var linkThread: Thread?
    // 以下三项由 linkLock 保护，串口线程也会访问
    nonisolated(unsafe) private var linkStop = false
    nonisolated(unsafe) private var linkPort: PosixSerialPort?
    nonisolated private let linkLock = NSLock()

    func scan() {
        let remembered = selected
        ports = Self.serialPorts().sorted { ($0.isLikelyEsp32 ? 0 : 1, $0.name) < ($1.isLikelyEsp32 ? 0 : 1, $1.name) }
        scanned = true
        if link == nil { firmware = .unknown }
        if let keep = ports.first(where: { $0.path == remembered }) {
            selected = keep.path
            message = keep.isLikelyEsp32 ? "已找到 ESP32 模块" : "找到 USB 串口，但无法确认是 ESP32"
        } else if let first = ports.first(where: \.isLikelyEsp32) ?? ports.first {
            selected = first.path
            message = ports.contains(where: \.isLikelyEsp32) ? "已找到 ESP32 模块" : "找到 USB 串口，但无法确认是 ESP32"
        } else {
            message = "没有找到。请用支持数据传输的 USB 线连接 ESP32；CH340 芯片的板子需要先安装沁恒的 CH34x 驱动。"
        }
    }

    /// 检测固件：发送握手，2 秒内收到 NotiBridge 固件的回复即成功。检测期间暂停串口连接。
    func checkFirmware() {
        guard !selected.isEmpty else { return }
        firmware = .checking
        let path = selected
        stopLink()
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = Self.handshake(path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch reply {
                    case let .success(line):
                        let version = line.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                        self.firmware = .found(version: version)
                        if self.mode == .esp32 { self.startLink() }
                    case let .failure(reason):
                        if case let .reason(text) = reason { self.firmware = .missing(text) }
                    }
                }
            }
        }
    }

    var needsFirmwareUpdate: Bool {
        if case let .found(v) = firmware { return Self.firmwareAvailable && v != Self.bundledVersion }
        return false
    }

    /// 刷写随 App 打包的固件（ESP32 ROM 下载协议，不需要 esptool）。
    func flash() {
        guard let url = Self.firmwareURL, let data = try? Data(contentsOf: url) else {
            message = "这个版本的 NotiBridge 没有附带 ESP32 固件。"
            return
        }
        guard !selected.isEmpty else { return }
        let path = selected
        stopLink()
        firmware = .flashing("正在进入下载模式…", 0)
        onLog?("开始刷写 ESP32 固件 \(Self.bundledVersion)（\(data.count / 1024) KB）")
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error> = Result {
                let port = try PosixSerialPort(path: path)
                defer { port.close() }
                let f = EspFlasher(port: port)
                f.onStage = { stage in
                    let (text, p): (String, Double) = switch stage {
                    case .connecting: ("正在进入下载模式…", 0)
                    case .erasing: ("正在擦除…", 0)
                    case let .writing(v): ("正在写入 \(Int(v * 100))%", v)
                    case .verifying: ("正在校验…", 1)
                    case .done: ("完成", 1)
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.firmware = .flashing(text, p) } }
                }
                try f.flash(image: [UInt8](data), offset: Self.firmwareOffset)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success:
                        self.onLog?("ESP32 固件刷写完成")
                        // 等固件启动后检测
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.checkFirmware() }
                    case let .failure(e):
                        let text = String(describing: e)
                        self.firmware = .flashFailed(text)
                        self.onLog?("ESP32 刷写失败：\(text)")
                    }
                }
            }
        }
    }

    // MARK: - 与固件的串口连接

    /// App 启动或切换到 ESP32 模式时调用：记住的串口存在就直接连接。
    func startLinkIfPossible() {
        guard mode == .esp32, linkThread == nil else { return }
        if selected.isEmpty || !FileManager.default.fileExists(atPath: selected) { scan() }
        guard !selected.isEmpty else { return }
        startLink()
    }

    func startLink() {
        guard linkThread == nil, !selected.isEmpty else { return }
        let path = selected
        linkStop = false
        let t = Thread { [weak self] in self?.linkLoop(path: path) }
        t.name = "esp32-link"
        linkThread = t
        t.start()
    }

    func stopLink() {
        linkLock.lock()
        linkStop = true
        linkPort?.close()
        linkLock.unlock()
        linkThread = nil
        link = nil
    }

    /// 打开配对窗口（3 分钟），让新的 iPhone 配对
    func pairNewIphone() { send("PAIR") }
    /// 删除 ESP32 上保存的所有 iPhone 配对
    func forgetIphones() { send("UNPAIR") }
    /// 在 iPhone 上执行通知的操作（0 = 正向，例如接听；1 = 负向，例如清除/拒接）
    func perform(uid: UInt32, positive: Bool) { send("ACT \(uid) \(positive ? 0 : 1)") }

    private func send(_ line: String) {
        linkLock.lock()
        let port = linkPort
        linkLock.unlock()
        try? port?.write(Array((line + "\n").utf8))
    }

    nonisolated private func linkLoop(path: String) {
        var announcedError = ""
        while true {
            let stop: Bool = { self.linkLock.lock(); defer { self.linkLock.unlock() }; return self.linkStop }()
            if stop { return }
            do {
                let port = try PosixSerialPort(path: path)
                // 不要让 RTS/DTR 把 ESP32 保持在复位或下载模式
                try port.setDTR(false)
                try port.setRTS(false)
                linkLock.lock()
                if linkStop { linkLock.unlock(); port.close(); return }
                linkPort = port
                linkLock.unlock()
                usleep(300_000)
                try port.write(Array("HB?\nSTATE?\n".utf8))
                announcedError = ""
                DispatchQueue.main.async { MainActor.assumeIsolated { self.linkError = "" } }
                var splitter = LineSplitter()
                var lastProbe = Date()
                while true {
                    let bytes = try port.read(timeout: 0.5)
                    for line in splitter.feed(bytes) {
                        guard let e = Esp32LinkParser.parse(line: line) else { continue }
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(e) } }
                    }
                    // 固件复位后（例如按了 EN）重新获取状态
                    if Date().timeIntervalSince(lastProbe) > 30 {
                        lastProbe = Date()
                        try port.write(Array("STATE?\n".utf8))
                    }
                }
            } catch {
                linkLock.lock()
                let stopped = linkStop
                linkPort = nil
                linkLock.unlock()
                if stopped { return }
                let text = String(describing: error)
                if text != announcedError {
                    announcedError = text
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.link = nil
                            self.linkError = "ESP32 已断开，正在重试：\(text)"
                        }
                    }
                }
                sleep(3)
            }
        }
    }

    private func handle(_ e: Esp32Event) {
        switch e {
        case let .hello(version, _, _):
            firmware = .found(version: version)
        case let .state(s):
            link = s
        case let .error(code, msg):
            onLog?("ESP32：\(msg)（\(code)）")
        default:
            break
        }
        onEvent?(e)
    }

    // MARK: - 串口枚举（IOKit）

    static func serialPorts() -> [Esp32Port] {
        var result: [Esp32Port] = []
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            // 跳过蓝牙等非 USB 串口
            if path.contains("Bluetooth") || path.contains("debug-console") { continue }
            let vid = parentInt(service, "idVendor")
            let pid = parentInt(service, "idProduct")
            if vid == nil && !path.contains("usb") { continue }
            let product = parentString(service, "USB Product Name") ?? (path as NSString).lastPathComponent
            result.append(Esp32Port(path: path, name: product, vendorId: vid, productId: pid))
        }
        return result
    }

    private static func parentInt(_ service: io_object_t, _ key: String) -> Int? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int
    }

    private static func parentString(_ service: io_object_t, _ key: String) -> String? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
    }

    // MARK: - 握手（POSIX 串口）

    enum HandshakeError: Error { case reason(String) }

    nonisolated static func handshake(path: String) -> Result<String, HandshakeError> {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return .failure(.reason("无法打开串口（可能被其他程序占用）")) }
        defer { close(fd) }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        // 打开串口会让多数开发板复位，等固件启动
        usleep(1_500_000)
        tcflush(fd, TCIOFLUSH)
        let probe = Array("HB?\n".utf8)
        _ = probe.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(2)
        var chunk = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                let text = String(decoding: buffer, as: UTF8.self)
                if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("HB-ESP32") }) {
                    return .success(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                usleep(50_000)
            }
        }
        return .failure(.reason(buffer.isEmpty ? "设备没有响应，可能还没有刷写 NotiBridge 固件" : "设备有输出，但不是 NotiBridge 固件"))
    }
}
