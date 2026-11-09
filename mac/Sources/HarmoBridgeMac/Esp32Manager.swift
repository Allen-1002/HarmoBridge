import Foundation
import IOKit
import IOKit.serial

/// 使用方式：纯软件，或使用 ESP32 模块（额外支持在电脑上接打电话）。与手机端、Windows 端一致。
enum UseMode: String, CaseIterable, Identifiable {
    case software
    case esp32

    var id: String { rawValue }
    var title: String { self == .software ? "纯软件（推荐）" : "使用 ESP32" }
    var detail: String {
        self == .software
            ? "同步通知、验证码自动复制，不需要任何额外硬件。不能接打电话。"
            : "在上面的基础上，还可以在 Mac 上接听、拨打电话。需要一块 ESP32 模块插在 Mac 的 USB 上，由 HarmoBridge 检测并刷写固件。"
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

/// ESP32 通话模块：检测已连接的硬件、检测固件、刷写固件（入口）。
/// 固件握手：以 115200 波特率发送 "HB?\n"，HarmoBridge 固件回复 "HB-ESP32 <版本> ..."。
/// 固件尚未发布，刷写暂时只提示。
@MainActor
final class Esp32Manager: ObservableObject {
    enum FirmwareState: Equatable {
        case unknown
        case checking
        case found(version: String)
        case missing(String)
        case flashing
    }

    @Published var mode: UseMode = UseMode(rawValue: UserDefaults.standard.string(forKey: "useMode") ?? "") ?? .software {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "useMode") }
    }
    @Published var ports: [Esp32Port] = []
    @Published var selected: String = ""
    @Published var firmware: FirmwareState = .unknown
    @Published var scanned = false
    @Published var message = ""

    /// 固件是否已经随 App 发布（发布后放在 App 资源里，并把这里改为 true）
    static let firmwareAvailable = false

    func scan() {
        ports = Self.serialPorts().sorted { ($0.isLikelyEsp32 ? 0 : 1, $0.name) < ($1.isLikelyEsp32 ? 0 : 1, $1.name) }
        scanned = true
        firmware = .unknown
        if let first = ports.first(where: \.isLikelyEsp32) ?? ports.first {
            selected = first.path
            message = ports.contains(where: \.isLikelyEsp32) ? "已找到 ESP32 模块" : "找到 USB 串口，但无法确认是 ESP32"
        } else {
            selected = ""
            message = "没有找到。请用支持数据传输的 USB 线连接 ESP32；CH340 芯片的板子在旧版 macOS 上需要先安装驱动。"
        }
    }

    /// 检测固件：发送握手，2 秒内收到 HarmoBridge 固件的回复即成功。
    func checkFirmware() {
        guard !selected.isEmpty else { return }
        firmware = .checking
        let path = selected
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = Self.handshake(path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch reply {
                    case let .success(line):
                        let version = line.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                        self.firmware = .found(version: version)
                    case let .failure(reason):
                        if case let .reason(text) = reason { self.firmware = .missing(text) }
                    }
                }
            }
        }
    }

    /// 刷写固件（入口）。固件发布前只提示。
    func flash() {
        guard Self.firmwareAvailable else {
            message = "ESP32 通话固件尚未发布，暂时无法刷写。固件发布后更新 HarmoBridge，在这里一键刷写即可。"
            return
        }
        firmware = .flashing
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
        return .failure(.reason(buffer.isEmpty ? "设备没有响应，可能还没有刷写 HarmoBridge 固件" : "设备有输出，但不是 HarmoBridge 固件"))
    }
}
