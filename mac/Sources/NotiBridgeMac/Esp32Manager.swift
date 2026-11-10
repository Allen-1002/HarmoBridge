import AppKit
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
    var chip: String? { UsbSerialChip.name(vendorId: vendorId, productId: productId) }

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
    /// ESP32 上配对过的 iPhone（固件 1.2.2 起逐台上报）
    @Published var iphones: [PairedIphone] = []
    /// 通话（固件 1.3.0 起）：免提连接、当前通话、配对过的手机、蓝牙配对码
    @Published var hfp: HfpLink?
    @Published var call: PhoneCall = .idle
    @Published var phones: [PairedPhone] = []
    @Published var pairCode: String?
    /// 固件最近报告的问题（iPhone 连上后清除）
    @Published var iphoneProblem = ""

    /// 收到固件事件（AppModel 处理通知）
    var onEvent: ((Esp32Event) -> Void)?
    var onLog: ((String) -> Void)?

    /// 固件不打包进 App：需要时从 GitHub 的固件 Release（firmware-v*）下载，校验签名后刷写。
    /// 下载过的固件缓存在 ~/Library/Caches/com.xsh.notibridge.desktop/esp32-firmware，没网时用缓存。
    static let firmwareCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.xsh.notibridge.desktop/esp32-firmware", isDirectory: true)
    /// GitHub 上最新的固件（nil = 还没查到）
    @Published var latestFirmware: FirmwareFeed.Firmware?
    private var feedCheckedAt: Date?
    /// 总是可以刷写（点刷写时再下载）
    static let firmwareAvailable = true
    /// 合并镜像（bootloader + 分区表 + 应用）从 0x1000 开始
    static let firmwareOffset: UInt32 = 0x1000
    /// 最新固件的版本号（界面显示用）
    var latestFirmwareVersion: String? { latestFirmware?.version }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": UpdateCore.userAgent, "Accept": "application/vnd.github+json"]
        return URLSession(configuration: c)
    }()

    /// 查询 GitHub 上最新的固件（最多每小时一次，force 时立即查）
    @discardableResult
    func refreshFirmwareFeed(force: Bool = false) async -> FirmwareFeed.Firmware? {
        if !force, let t = feedCheckedAt, Date().timeIntervalSince(t) < 3600, latestFirmware != nil { return latestFirmware }
        do {
            let (data, resp) = try await Self.session.data(from: FirmwareFeed.releasesURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            if let fw = try FirmwareFeed.latest(fromReleasesJSON: data) {
                latestFirmware = fw
                feedCheckedAt = Date()
            }
        } catch {
            onLog?("查询 ESP32 固件失败：\(error.localizedDescription)")
        }
        return latestFirmware
    }

    /// 下载并校验固件；已缓存且校验通过的直接用。没网时用缓存里最新的。
    private func obtainFirmware() async throws -> (version: String, image: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.firmwareCacheDir, withIntermediateDirectories: true)
        func cached(_ v: String) -> Data? {
            let dir = Self.firmwareCacheDir
            guard let img = try? Data(contentsOf: dir.appendingPathComponent(FirmwareFeed.assetName(version: v))),
                  let sums = try? Data(contentsOf: dir.appendingPathComponent("\(v).sums")),
                  let sig = try? Data(contentsOf: dir.appendingPathComponent("\(v).sig")),
                  (try? FirmwareFeed.verify(image: img, version: v, sums: sums, signature: sig)) != nil else { return nil }
            return img
        }
        if let fw = await refreshFirmwareFeed(force: true) {
            if let img = cached(fw.version) { return (fw.version, img) }
            func get(_ a: UpdateCore.Asset) async throws -> Data {
                let (d, r) = try await Self.session.data(from: a.browserDownloadURL)
                guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return d
            }
            let img = try await get(fw.image), sums = try await get(fw.sums), sig = try await get(fw.signature)
            try FirmwareFeed.verify(image: img, version: fw.version, sums: sums, signature: sig)
            let dir = Self.firmwareCacheDir
            try? img.write(to: dir.appendingPathComponent(FirmwareFeed.assetName(version: fw.version)))
            try? sums.write(to: dir.appendingPathComponent("\(fw.version).sums"))
            try? sig.write(to: dir.appendingPathComponent("\(fw.version).sig"))
            return (fw.version, img)
        }
        // 离线：缓存里最新的已校验固件
        let names = (try? fm.contentsOfDirectory(atPath: Self.firmwareCacheDir.path)) ?? []
        let versions = names.compactMap { n -> String? in
            guard n.hasPrefix("NotiBridge-ESP32-"), n.hasSuffix(".bin") else { return nil }
            return String(n.dropFirst("NotiBridge-ESP32-".count).dropLast(4))
        }.sorted { UpdateCore.isNewer($0, than: $1) }
        for v in versions { if let img = cached(v) { return (v, img) } }
        throw URLError(.notConnectedToInternet)
    }

    private var linkThread: Thread?
    // 以下三项由 linkLock 保护，串口线程也会访问
    nonisolated(unsafe) private var linkStop = false
    nonisolated(unsafe) private var linkPort: PosixSerialPort?
    nonisolated private let linkLock = NSLock()

    private var knownPortPaths: [String] = []
    private var portWatch: Timer?

    /// 插拔板子后串口会变：每 2 秒看一次串口列表，变了就重新检测；正在用的串口没了或换了板子，就把连接切到新串口。
    func startPortWatch() {
        guard portWatch == nil else { return }
        portWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refreshPortsIfChanged() }
        }
    }

    @discardableResult
    func refreshPortsIfChanged() -> Bool {
        if case .flashing = firmware { return false }
        if firmware == .checking { return false }
        let paths = Self.serialPorts().map(\.path).sorted()
        guard paths != knownPortPaths else { return false }
        let before = selected
        scan()
        if selected != before || !paths.contains(before) {
            stopLink()
            if !selected.isEmpty { checkFirmware() }
        } else if mode == .esp32, !selected.isEmpty, linkThread == nil {
            startLink()
        }
        return true
    }

    func scan() {
        knownPortPaths = Self.serialPorts().map(\.path).sorted()
        let remembered = selected
        ports = Self.serialPorts().sorted { ($0.isLikelyEsp32 ? 0 : 1, $0.name) < ($1.isLikelyEsp32 ? 0 : 1, $1.name) }
        scanned = true
        if link == nil { firmware = .unknown }
        // 记住的串口只有在仍然像 ESP32（或没有别的像 ESP32 的串口）时才沿用
        if let keep = ports.first(where: { $0.path == remembered }),
           keep.isLikelyEsp32 || !ports.contains(where: \.isLikelyEsp32) {
            selected = keep.path
            message = keep.isLikelyEsp32 ? "已找到 ESP32 模块" : "找到 USB 串口，但无法确认是 ESP32"
        } else if let first = ports.first(where: \.isLikelyEsp32) ?? ports.first {
            selected = first.path
            message = ports.contains(where: \.isLikelyEsp32) ? "已找到 ESP32 模块" : "找到 USB 串口，但无法确认是 ESP32"
        } else {
            selected = ""
            let missing = Self.usbSerialChipsWithoutPort(known: ports)
            message = missing.isEmpty ? UsbSerialChip.notFoundMessage : UsbSerialChip.driverMissingMessage(chips: missing)
        }
    }

    /// 插着的 USB 串口芯片里，没有对应串口的那些（= 缺驱动）
    static func usbSerialChipsWithoutPort(known: [Esp32Port]) -> [String] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func int(_ k: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            let vid = int("idVendor"), pid = int("idProduct")
            guard let chip = UsbSerialChip.name(vendorId: vid, productId: pid) else { continue }
            if known.contains(where: { $0.vendorId == vid && $0.productId == pid }) { continue }
            result.append(chip)
        }
        return result
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

    /// GitHub 上有比板子上更新的固件
    var needsFirmwareUpdate: Bool {
        if case let .found(v) = firmware, let latest = latestFirmware?.version { return UpdateCore.isNewer(latest, than: v) }
        return false
    }

    /// 原固件备份（不在 App 数据目录里，“清除所有数据”和卸载都不会删掉）
    static let backupStore = EspBackupStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotiBridge ESP32 Backups", isDirectory: true))
    @Published var backups: [EspBackupInfo] = Esp32Manager.backupStore.all()

    private static func stageText(_ stage: EspFlasher.Stage, restoring: Bool) -> (String, Double) {
        switch stage {
        case .connecting: return ("正在进入下载模式…", 0)
        case let .backingUp(v): return ("正在备份原固件 \(Int(v * 100))%（只在第一次刷写时备份）", v)
        case .erasing: return ("正在擦除…", 0)
        case let .writing(v): return ("正在\(restoring ? "还原" : "写入") \(Int(v * 100))%", v)
        case .verifying: return ("正在校验…", 1)
        case .done: return ("完成", 1)
        }
    }

    /// 下载最新固件并刷写（ESP32 ROM 下载协议，不需要 esptool）。第一次刷写某块板子前自动备份原固件。
    func flash() {
        guard !selected.isEmpty else { return }
        firmware = .flashing("正在下载固件…", 0)
        Task {
            let fw: (version: String, image: Data)
            do {
                fw = try await obtainFirmware()
            } catch {
                firmware = .flashFailed("无法下载固件（\(error.localizedDescription)）。请检查网络后重试。")
                return
            }
            flash(image: fw.image, version: fw.version)
        }
    }

    private func flash(image data: Data, version: String) {
        onLog?("开始刷写 ESP32 固件 \(version)（\(data.count / 1024) KB）")
        runOnBoard(restoring: false) { port, onStage, log in
            let outcome = try EspFirmwareInstaller.install(image: [UInt8](data), port: port, store: Self.backupStore,
                                                           onStage: onStage, log: log)
            switch outcome {
            case .created: return "ESP32 固件刷写完成，原固件已备份，可以随时还原"
            case .kept: return "ESP32 固件刷写完成（原固件备份已存在，保留不动）"
            case .alreadyNotiBridge: return "ESP32 固件刷写完成（板子上原本就是 NotiBridge 固件，没有可备份的原固件）"
            }
        }
    }

    /// 把板子还原为第一次刷写 NotiBridge 之前的原固件。
    func restoreOriginal() {
        onLog?("开始还原 ESP32 原固件")
        runOnBoard(restoring: true) { port, onStage, log in
            let info = try EspFirmwareInstaller.restore(port: port, store: Self.backupStore, onStage: onStage, log: log)
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return "已还原为原固件（备份于 \(f.string(from: info.createdAt))）"
        }
    }

    func revealBackups() {
        try? FileManager.default.createDirectory(at: Self.backupStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.backupStore.directory)
    }

    private func runOnBoard(restoring: Bool,
                            _ work: @escaping (PosixSerialPort, @escaping (EspFlasher.Stage) -> Void,
                                               @escaping (String) -> Void) throws -> String) {
        guard !selected.isEmpty else { return }
        let path = selected
        stopLink()
        firmware = .flashing("正在进入下载模式…", 0)
        let log: (String) -> Void = { s in DispatchQueue.main.async { MainActor.assumeIsolated { self.onLog?(s) } } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error> = Result {
                let port = try PosixSerialPort(path: path)
                defer { port.close() }
                return try work(port, { stage in
                    let (text, p) = Self.stageText(stage, restoring: restoring)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.firmware = .flashing(text, p) } }
                }, log)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.backups = Self.backupStore.all()
                    switch result {
                    case let .success(text):
                        self.onLog?(text)
                        self.message = text
                        if restoring {
                            // 原固件不是 NotiBridge：不再自动连接，直到重新检测或刷写
                            self.firmware = .unknown
                        } else {
                            // 等固件启动后检测
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.checkFirmware() }
                        }
                    case let .failure(e):
                        let text = String(describing: e)
                        self.firmware = .flashFailed(text)
                        self.onLog?("ESP32 \(restoring ? "还原" : "刷写")失败：\(text)")
                    }
                }
            }
        }
    }

    // MARK: - 与固件的串口连接

    /// App 启动或切换到 ESP32 模式时调用：记住的串口存在就直接连接。
    func startLinkIfPossible() {
        startPortWatch()
        guard mode == .esp32, linkThread == nil else { return }
        Task { await refreshFirmwareFeed() }
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
        iphones = []
        hfp = nil
        call = .idle
        phones = []
    }

    /// 打开配对窗口（3 分钟），让新的 iPhone 配对
    func pairNewIphone() { send("PAIR") }
    /// 删除 ESP32 上保存的所有 iPhone 配对
    func forgetIphones() { send("UNPAIR") }
    // MARK: 通话控制
    func answer() { send("ANSWER") }
    /// 来电时拒接，通话中/呼出时挂断
    func hangUp() { send("HANGUP") }
    func dial(_ number: String) {
        let n = number.filter { "0123456789+*#".contains($0) }
        guard !n.isEmpty, n.count < 32 else { return }
        send("DIAL \(n)")
    }
    func redial() { send("REDIAL") }
    func sendDtmf(_ c: Character) { if "0123456789*#".contains(c) { send("DTMF \(c)") } }
    /// 通话声音走电脑还是留在手机上
    func setAudioToPC(_ on: Bool) { send(on ? "AUDIO PC" : "AUDIO PHONE") }
    func connectPhone(_ id: String? = nil) { send(id.map { "HFP CONNECT \($0)" } ?? "HFP CONNECT") }
    func disconnectPhone() { send("HFP DISCONNECT") }
    private static func isAddr(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil
    }
    /// 设为通话优先手机（nil 取消）
    func preferPhone(_ id: String?) {
        if let id { if Self.isAddr(id) { send("PREFER \(id)") } } else { send("PREFER NONE") }
    }
    /// 通话切换到这台手机（断开当前的再连它）
    func switchPhone(_ id: String) { if Self.isAddr(id) { send("SWITCH \(id)") } }
    /// 删除一台手机的通话配对（id 是 PairedPhone.id）
    func forgetPhone(_ id: String) {
        guard id.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil else { return }
        send("UNPAIR_BT \(id)")
    }

    /// 删除一台 iPhone 的配对（id 是 PairedIphone.id）
    func forgetIphone(_ id: String) {
        guard id.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil else { return }
        send("UNPAIR \(id)")
    }
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
                try port.write(Array("HB?\nSTATE?\nBONDS?\nPHONES?\n".utf8))
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
            Task { await refreshFirmwareFeed() }
        case let .bonds(list):
            iphones = list
        case let .hfp(h):
            hfp = h
        case let .call(c):
            call = c
            if !c.isIdle { pairCode = nil }
        case let .phones(list):
            phones = list
        case let .pairCode(code):
            pairCode = code
        case let .state(s):
            link = s
            if s.ble == "ready" { iphoneProblem = "" }
        case let .error(code, msg):
            iphoneProblem = msg
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
