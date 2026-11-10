import AppKit
import Combine
import Foundation
import NotiBridgeCore
import IOBluetooth
import ServiceManagement
import SwiftUI

struct ReceivedRecord: Identifiable {
    let id = UUID()
    let at: Date
    let notification: MirroredNotification
    let result: String
    /// 来自哪台手机（deviceId）
    var deviceId: String = ""
}

struct LogLine: Identifiable {
    let id = UUID()
    let at: Date
    let text: String
}

@MainActor
final class AppModel: ObservableObject {
    static let defaultPort: UInt16 = 47800

    @Published var listening = "未启动"
    @Published var onlineDevices: [String: Date] = [:] // deviceId -> 最后活动时间
    @Published var pairedDevices: [PairingStore.Device] = []
    /// 用户在电脑上给手机起的名字（deviceId -> 名字），只保存在本机
    @Published var deviceAliases: [String: String] =
        UserDefaults.standard.dictionary(forKey: "deviceAliases") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(deviceAliases, forKey: "deviceAliases") }
    }
    @Published var pairingPin: String?
    @Published var pairingSas: String?
    @Published var paused = false {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            if oldValue != paused { touchSettings() }
        }
    }
    @Published var filter: SyncFilter {
        didSet {
            saveFilter()
            if oldValue.blockSensitive != filter.blockSensitive { touchSettings() }
        }
    }
    @Published var records: [ReceivedRecord] = []
    @Published var logs: [LogLine] = []
    @Published var notificationsAllowed = "未知"
    @Published var loginItemEnabled = false
    @Published var showContentInList = false
    /// “添加设备”弹窗（主窗口里显示）
    @Published var showAddDevice = false
    @Published var addDeviceKind: AddDeviceKind?
    // 通话（实验）
    @Published var callState: CallState = .unavailable("未连接")
    @Published var btDevices: [BTDevice] = []
    @Published var selectedBT: String = UserDefaults.standard.string(forKey: "hfpDevice") ?? ""
    private var callBridge: CallBridge?
    /// ESP32 通话模块（使用方式、硬件检测、固件）
    let esp32 = Esp32Manager()
    private var esp32Changes: AnyCancellable?
    /// 自动更新（GitHub Releases）
    let updater = Updater()
    private var updaterChanges: AnyCancellable?

    let port: UInt16
    private let store: PairingStore
    private let window = PairingWindow()
    private let deduper = NotificationDeduper()
    private let notifier = Notifier()
    private var server: BridgeServer!
    private var connectionDevice: [ObjectIdentifier: String] = [:]
    private var pinTimer: Timer?
    private var repairNeeded = false
    private var lastOutdatedNotice: Date?

    init() {
        let stored = UserDefaults.standard.integer(forKey: "port")
        port = stored > 0 && stored < 65536 ? UInt16(stored) : Self.defaultPort
        if let data = UserDefaults.standard.data(forKey: "filter"),
           let f = try? JSONDecoder().decode(SyncFilter.self, from: data) {
            filter = f
        } else {
            filter = SyncFilter()
        }
        paused = UserDefaults.standard.bool(forKey: "paused")
        let macId = Self.macId()
        store = PairingStore(macId: macId)
        let macName = Host.current().localizedName ?? "Mac"
        repairNeeded = Self.migratePairingSchema(store: store)
        server = BridgeServer { [store, window] in
            SessionMachine(store: store, window: window, macId: macId, macName: macName)
        }
        server.onEvent = { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        server.start(port: port, serviceName: "NotiBridge-\(macName)", macId: macId)
        pairedDevices = store.devices()
        // ESP32 状态变化时刷新界面（引导页、设置页通过 model 读取）
        esp32Changes = esp32.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        updaterChanges = updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        updater.onLog = { [weak self] s in self?.log(s) }
        // 正在配对手机时不更新（更新会重启应用，打断配对）
        updater.canUpdateNow = { [weak self] in
            guard let self else { return true }
            return self.pairingPin == nil && self.pairingSas == nil
        }
        updater.onUpdated = { [weak self] v in
            self?.notifier.showLocal(title: "已更新到 \(v)", body: "NotiBridge 已自动更新并重新打开。")
        }
        updater.start()
        esp32.onLog = { [weak self] s in self?.log(s) }
        esp32.onEvent = { [weak self] e in self?.handleEsp32(e) }
        esp32.startLinkIfPossible()
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        // 首次使用由引导页统一申请权限；完成引导后启动时只确认通知权限
        if onboarded {
            refreshNotificationStatus()
        }
        if let p = store.loadProblem { log(p) }
        if repairNeeded {
            // 自动更新重启后（或手动安装后）第一次启动 1.1.0：说明为什么要重新配对
            DispatchQueue.main.async { [weak self] in self?.showRepairNotice() }
        }
    }

    /// 1.1.0 起配对协议为 v2（CPace），旧配对一律作废。只在第一次启动时清除一次。
    static let pairingSchema = 2
    static let repairNoticeText = "安全升级：配对方式已更新，请在电脑和手机上重新配对"

    /// 清除旧版（协议 v1）配对。返回是否需要提示用户重新配对（以前用过、或有过配对）。
    private static func migratePairingSchema(store: PairingStore) -> Bool {
        let d = UserDefaults.standard
        guard d.integer(forKey: "pairingSchema") < pairingSchema else { return false }
        let hadPairings = store.removePairingFile() > 0
        d.set(pairingSchema, forKey: "pairingSchema")
        return hadPairings || d.bool(forKey: "onboarded")
    }

    private func showRepairNotice() {
        log(Self.repairNoticeText)
        showFrontAlert(
            title: Self.repairNoticeText,
            text: "NotiBridge 1.1.0 是安全更新：配对改用 PAKE（CPace），即使有人录下了配对过程也无法离线猜出配对码，并加了双向防重放。旧的配对已失效并已清除。\n\n请在这台电脑上点“添加设备”，再在每台手机上（也要更新到 1.1.0）重新配对一次。")
    }

    /// 菜单栏应用（accessory）弹出的对话框容易被当前窗口挡住：激活应用、提到浮动层级并强制置前
    private func showFrontAlert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好的")
        alert.layout()
        alert.window.level = .floating
        alert.window.center()
        alert.window.orderFrontRegardless()
        alert.window.makeKey()
        alert.runModal()
    }

    /// 首次启动引导是否已完成
    @Published var onboarded: Bool = UserDefaults.standard.bool(forKey: "onboarded")

    func finishOnboarding() {
        onboarded = true
        UserDefaults.standard.set(true, forKey: "onboarded")
        refreshNotificationStatus()
        log("首次启动引导已完成")
    }

    func restartOnboarding() {
        onboarded = false
        UserDefaults.standard.set(false, forKey: "onboarded")
    }

    func refreshNotificationStatus() {
        notifier.authorizationStatus { [weak self] st in
            let ok = st == .authorized || st == .provisional
            self?.notificationsAllowed = ok ? "已允许" : "未允许"
            if !ok {
                self?.log("macOS 通知权限未允许，请在 系统设置 > 通知 > NotiBridge 中开启")
            }
        }
    }

    /// 有手机 App 在线，或有经 ESP32 的 iPhone 已就绪
    var isPhoneOnline: Bool { !onlineDevices.isEmpty || iphoneDevices.contains(where: \.ancsReady) }

    /// 最近一次与手机通信（含通知订阅扩展的按需连接）
    @Published var lastSync: Date?

    var statusSymbol: String {
        if paused { return "pause.circle" }
        if isPhoneOnline { return "iphone.radiowaves.left.and.right" }
        return hasAnyDevice ? "iphone" : "iphone.slash"
    }

    /// 手机 App 不在前台时，通知由系统拉起的订阅扩展按需连接转发，所以“未连接”不等于收不到通知。
    var phoneStatusText: String {
        if isPhoneOnline { return "已连接" }
        if !hasAnyDevice { return "未配对" }
        guard let lastSync else { return "待命（有通知时自动连接）" }
        return "待命 · 最近同步 \(lastSync.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - 配对

    func openPairing() {
        window.open()
        pairingPin = window.activePin()
        pairingSas = nil
        log("已开启配对，PIN 2 分钟内有效")
        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pin = self.window.activePin()
                if pin == nil && self.pairingPin != nil {
                    self.pairingPin = nil
                    self.log("配对窗口已关闭")
                    self.pinTimer?.invalidate()
                }
            }
        }
    }

    func cancelPairing() {
        window.close()
        pairingPin = nil
        pairingSas = nil
        pinTimer?.invalidate()
    }

    func unpair(_ d: PairingStore.Device) {
        // 手机在线：先通知手机同步删除；离线：手机下次连接时会收到 unknown_device，只提示用户重新配对或手动删除
        let notified = server.unpair(deviceId: d.id)
        store.remove(deviceId: d.id)
        let name = displayName(d.id)
        deviceAliases.removeValue(forKey: d.id)
        pairedDevices = store.devices()
        onlineDevices.removeValue(forKey: d.id)
        log(notified ? "已取消配对：\(name)（已通知手机同步删除）"
                     : "已取消配对：\(name)（手机不在线，下次连接时手机会提示这台电脑已取消配对，需要在手机上手动删除）")
    }

    // MARK: - 手机名字

    /// 手机显示名：自定义了名字就用自定义名字，否则用手机配对时报告的名字。
    func displayName(_ id: String) -> String {
        if let a = deviceAliases[id], !a.isEmpty { return a }
        if id.hasPrefix(Self.iphoneDeviceId) {
            // 经 ESP32 的 iPhone：用 ESP32 读到的 iPhone 名字
            let addr = id.dropFirst(Self.iphoneDeviceId.count + 1)
            return esp32.iphones.first { $0.id == addr }?.displayName ?? "iPhone"
        }
        return pairedDevices.first { $0.id == id }?.name ?? String(id.prefix(8))
    }

    /// 给手机改名；名字为空或与手机原名相同则恢复原名。
    func rename(_ d: PairingStore.Device, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == d.name {
            deviceAliases.removeValue(forKey: d.id)
            log("\(d.name) 已恢复原名")
        } else {
            deviceAliases[d.id] = n
            log("已把 \(d.name) 命名为 \(n)")
        }
    }

    /// 配对了多台手机时，通知里才标出来源手机
    func sourceLabel(_ deviceId: String) -> String? {
        // 同时有局域网手机和经 ESP32 的 iPhone 时也标出来源
        let sources = pairedDevices.count + (esp32.mode == .esp32 ? max(1, esp32.iphones.count) : 0)
        guard sources > 1, !deviceId.isEmpty else { return nil }
        return displayName(deviceId)
    }

    // MARK: - 通话（实验）

    struct BTDevice: Identifiable, Hashable {
        let id: String // 蓝牙地址
        let name: String
    }

    func refreshBTDevices() {
        btDevices = HFPCallBridge.pairedDevices().map {
            BTDevice(id: $0.addressString ?? "", name: $0.name ?? ($0.addressString ?? "未知"))
        }
        log("已读取 Mac 上已配对的蓝牙设备 \(btDevices.count) 个")
    }

    func connectCall() {
        guard let dev = HFPCallBridge.pairedDevices().first(where: { $0.addressString == selectedBT }) else {
            log("请先选择已配对的手机")
            return
        }
        UserDefaults.standard.set(selectedBT, forKey: "hfpDevice")
        callBridge?.disconnect()
        let bridge = HFPCallBridge(device: dev)
        bridge.onLog = { [weak self] s in
            MainActor.assumeIsolated { self?.log("[电话] \(s)") }
        }
        bridge.onStateChange = { [weak self] st in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.callState = st
                    if case let .incoming(n) = st {
                        self.notifier.showCall(number: n)
                    } else {
                        self.notifier.clearCall()
                    }
                }
            }
        }
        callBridge = bridge
        bridge.connect()
    }

    func disconnectCall() {
        callBridge?.disconnect()
        callBridge = nil
        callState = .unavailable("已断开")
    }

    func answerCall() { callBridge?.answer() }
    func hangUpCall() { callBridge?.hangUp() }
    func dial(_ n: String) { callBridge?.dial(n) }
    func audioToMac() { callBridge?.audioToComputer() }
    func audioToPhone() { callBridge?.audioToPhone() }

    // MARK: - 蓝牙辅助

    /// Mac 的蓝牙名称（手机扫描时看到的名字）
    var macBluetoothName: String {
        IOBluetoothHostController.default()?.nameAsString() ?? (Host.current().localizedName ?? "Mac")
    }

    /// 打开 系统设置 > 蓝牙。保持该页面打开时 Mac 可被手机搜到。
    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyAgain(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    // 今日统计
    var todayRecords: [ReceivedRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return records.filter { $0.at >= start }
    }
    var todayShown: Int { todayRecords.filter { $0.result == "shown" }.count }
    var todayFiltered: Int { todayRecords.filter { $0.result == "filtered" }.count }
    @Published var todayOtp = 0

    // MARK: - 设置

    func setLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("设置开机启动失败：\(error.localizedDescription)")
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            log("开机启动需要在 系统设置 > 通用 > 登录项 中允许")
        }
    }

    // MARK: - 卸载与重置

    /// 本应用在这台 Mac 上留下数据的位置（不含钥匙串、登录项）。
    static var dataLocations: [URL] {
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        var ids = ["com.xsh.notibridge.desktop", "com.xsh.notibridge.mac"]
        if let b = Bundle.main.bundleIdentifier, !ids.contains(b) { ids.insert(b, at: 0) }
        var urls: [URL] = []
        for id in ids {
            urls.append(lib.appendingPathComponent("Caches/\(id)", isDirectory: true))
            urls.append(lib.appendingPathComponent("Application Support/\(id)", isDirectory: true))
            urls.append(lib.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true))
            urls.append(lib.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true))
            urls.append(lib.appendingPathComponent("WebKit/\(id)", isDirectory: true))
        }
        urls.append(lib.appendingPathComponent("Application Support/NotiBridge", isDirectory: true))
        return urls
    }

    /// 清除所有数据：断开手机、停止服务，删除配对文件和旧版钥匙串密钥、偏好设置、缓存、登录项和已送达的通知。
    func resetAllData() {
        log("正在清除所有数据…")
        cancelPairing()
        disconnectCall()
        server.disconnectAll()
        server.stop()
        onlineDevices.removeAll()
        let removedKeys = store.removeAll()
        pairedDevices = []
        deviceAliases = [:]
        // 登录项
        if SMAppService.mainApp.status != .notRegistered {
            try? SMAppService.mainApp.unregister()
        }
        loginItemEnabled = false
        // 通知
        notifier.removeEverything()
        // 偏好设置（UserDefaults）
        let defaults = UserDefaults.standard
        for id in Set([Bundle.main.bundleIdentifier ?? "", "com.xsh.notibridge.desktop", "com.xsh.notibridge.mac"])
            where !id.isEmpty {
            defaults.removePersistentDomain(forName: id)
        }
        for key in ["onboarded", "paused", "filter", "port", "macId", "copyOtp", "settingsUpdatedAt",
                    "hfpDevice", "deviceAliases", "useMode", "updateAutoCheck", "updateAutoInstall", "updatePendingVersion", "lastLaunchedVersion"] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
        // 文件
        let fm = FileManager.default
        for url in Self.dataLocations where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        records.removeAll()
        NSLog("NotiBridge: 已清除所有数据（配对密钥 \(removedKeys) 个）")
    }

    /// 清除所有数据后重新启动应用，回到首次启动引导。
    func resetAndRelaunch() {
        resetAllData()
        let path = Bundle.main.bundleURL.path
        if path.hasSuffix(".app") {
            // 等当前进程退出后再打开新实例
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    /// 卸载：清除所有数据，把 NotiBridge.app 移到废纸篓，然后退出。
    func uninstallApp() {
        resetAllData()
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: &trashed)
        } catch {
            let alert = NSAlert()
            alert.messageText = "数据已清除，但无法把应用移到废纸篓"
            alert.informativeText = "请在“应用程序”文件夹里手动把 NotiBridge 拖到废纸篓。\n\(error.localizedDescription)"
            alert.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
        }
        NSApp.terminate(nil)
    }

    func sendLocalTestNotification() {
        let n = MirroredNotification(id: "local-test-\(Int(Date().timeIntervalSince1970))", bundleName: "local",
                                     appName: "NotiBridge 本机自检", title: "Mac 通知通道正常",
                                     text: "这条通知由 Mac 本机生成，不来自手机。", time: Date(), isTest: true)
        notifier.show(n)
        log("已发送本机自检通知（不经过手机）")
    }

    func localAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append("\(String(cString: host)) (\(name))")
            }
        }
        return result
    }

    // MARK: - 事件处理

    private func handle(_ e: BridgeServer.Event) {
        switch e {
        case let .listening(p):
            listening = "监听中 :\(p)"
            log("WebSocket 服务已启动，端口 \(p)，Bonjour \(BridgeServer.serviceType)")
        case let .stopped(reason):
            listening = reason
            log("服务状态：\(reason)")
        case let .disconnected(conn, deviceId, wasAuth):
            connectionDevice.removeValue(forKey: conn)
            if wasAuth, let deviceId, !connectionDevice.values.contains(deviceId) {
                onlineDevices.removeValue(forKey: deviceId)
                log("手机已断开：\(deviceName(deviceId))")
            }
        case let .output(out, conn):
            handleOutput(out, conn: conn)
        case let .rejected(ip, reason):
            log("拒绝来自 \(ip) 的连接：\(reason)")
        }
    }

    private func handleOutput(_ out: SessionMachine.Output, conn: ObjectIdentifier) {
        switch out {
        case .send, .close:
            break
        case let .log(text):
            log(text)
        case .peerOutdated:
            // 旧版手机（1.0.x）连不上新协议：提示一次（每小时最多一次）
            if lastOutdatedNotice.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                lastOutdatedNotice = Date()
                notifier.showLocal(title: "有旧版手机尝试连接", body: "对方版本过旧，请把电脑和手机都更新到 1.1.0，然后重新配对。")
            }
        case let .pairingStarted(sas):
            pairingSas = sas
            log("手机发起配对，请核对两端校验码：\(sas)")
        case let .paired(deviceId, name, _):
            pairedDevices = store.devices()
            pairingPin = nil
            pairingSas = nil
            pinTimer?.invalidate()
            log("配对成功：\(name)（\(deviceId.prefix(8))…）")
        case let .authenticated(deviceId):
            connectionDevice[conn] = deviceId
            onlineDevices[deviceId] = Date()
            lastSync = Date()
            log("手机已认证上线：\(deviceName(deviceId))")
        case let .unpaired(deviceId):
            let name = deviceName(deviceId)
            pairedDevices = store.devices()
            connectionDevice.removeValue(forKey: conn)
            onlineDevices.removeValue(forKey: deviceId)
            log("\(name) 在手机上删除了这台电脑，已同步取消配对")
        case let .ping(seq):
            touch(conn)
            server.ack(seq: seq, result: "pong", to: conn)
        case let .notify(n, seq):
            touch(conn)
            let result = present(n, from: connectionDevice[conn] ?? "")
            server.ack(seq: seq, result: result, to: conn)
        case let .settings(st, seq):
            touch(conn)
            handleRemoteSettings(st, seq: seq, conn: conn)
        case let .otp(o, seq):
            touch(conn)
            server.ack(seq: seq, result: handleOtp(o, from: connectionDevice[conn] ?? ""), to: conn)
        case let .cancel(ids, seq):
            touch(conn)
            // 通知 id 按手机区分：不同手机的 hashCode 可能相同
            let dev = connectionDevice[conn] ?? ""
            let keys = ids.map { scopedId(dev, $0) }
            notifier.remove(keys)
            keys.forEach(deduper.remove)
            log("手机撤销通知 \(ids.count) 条")
            server.ack(seq: seq, result: "removed", to: conn)
        }
    }

    // MARK: - 经 ESP32 收到的 iPhone 通知（ANCS）

    /// 经 ESP32 的 iPhone 的来源 id："iphone:<蓝牙地址>"（旧固件没有地址时为 "iphone"）
    static let iphoneDeviceId = "iphone"
    private static func iphoneSource(_ peer: String) -> String { peer.isEmpty ? iphoneDeviceId : "\(iphoneDeviceId):\(peer)" }
    private var lastIphoneBle = ""

    private func handleEsp32(_ e: Esp32Event) {
        switch e {
        case let .notification(n):
            // 连接时 iPhone 会补发通知中心里已有的通知：不弹出
            if n.preExisting { return }
            let m = n.mirrored()
            if !paused, !filter.blacklist.contains(m.bundleName), copyOtp {
                let code = OtpExtractor.extract(title: m.title, text: m.text)
                if !code.isEmpty {
                    if filter.blockSensitive && OtpExtractor.isFinance(bundleName: m.bundleName, title: m.title, text: m.text) {
                        log("已跳过银行/支付类验证码（\(m.appName)）")
                    } else {
                        _ = handleOtp(OtpCode(id: m.id, bundleName: m.bundleName, appName: m.appName, code: code),
                                      from: Self.iphoneSource(n.peer))
                    }
                    return
                }
            }
            _ = present(m, from: Self.iphoneSource(n.peer))
        case let .removed(uid, peer):
            let key = scopedId(Self.iphoneSource(peer), "ios-\(uid)")
            notifier.remove([key])
            deduper.remove(key)
        case let .call(c):
            handleCall(c)
        case let .state(s):
            if s.ble != lastIphoneBle {
                if s.ble == "ready" { log("iPhone 已通过 ESP32 连接") }
                else if lastIphoneBle == "ready" { log("iPhone 已断开，ESP32 等待重新连接") }
                lastIphoneBle = s.ble
            }
        default:
            break
        }
    }

    /// 来电时弹系统通知，接通或结束后收起
    private var lastCallState = "idle"
    private func handleCall(_ c: PhoneCall) {
        defer { lastCallState = c.state }
        guard c.state != lastCallState else { return }
        switch c.state {
        case "incoming":
            notifier.showCall(number: c.number.isEmpty ? "未知号码" : c.number)
            log("来电 \(c.number.isEmpty ? "未知号码" : c.number)（经 ESP32）")
        case "active":
            notifier.clearCall()
            log("通话已接通")
        case "idle":
            notifier.clearCall()
            if lastCallState != "idle" { log("通话结束") }
        default:
            break
        }
    }

    private func scopedId(_ deviceId: String, _ id: String) -> String {
        // iPhone 的来源 id 前 8 位相同，要用完整 id 区分不同的 iPhone
        deviceId.hasPrefix(Self.iphoneDeviceId) ? "\(deviceId)-\(id)" : "\(deviceId.prefix(8))-\(id)"
    }

    private func present(_ original: MirroredNotification, from deviceId: String) -> String {
        var n = original
        n.id = scopedId(deviceId, original.id)
        let result: String
        if paused {
            result = "paused"
        } else if case let .block(reason) = filter.decide(bundleName: n.bundleName, title: n.title, text: n.text) {
            result = "filtered"
            log("已过滤 \(n.bundleName)：\(reason)")
        } else {
            switch deduper.check(n) {
            case .duplicate:
                result = "duplicate"
            case .new, .updated:
                notifier.show(n, source: sourceLabel(deviceId))
                result = "shown"
            }
        }
        records.insert(ReceivedRecord(at: Date(), notification: n, result: result, deviceId: deviceId), at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        return result
    }

    @Published var copyOtp: Bool = UserDefaults.standard.object(forKey: "copyOtp") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(copyOtp, forKey: "copyOtp")
            if oldValue != copyOtp { touchSettings() }
        }
    }

    // MARK: - 与手机同步的开关（暂停同步、敏感通知过滤、验证码复制）

    /// 正在应用手机同步过来的设置时为 true，避免把修改时间刷新成现在。
    private var applyingRemote = false

    private var settingsUpdatedAt: Double {
        get { UserDefaults.standard.double(forKey: "settingsUpdatedAt") }
        set { UserDefaults.standard.set(newValue, forKey: "settingsUpdatedAt") }
    }

    private func touchSettings() {
        guard !applyingRemote else { return }
        settingsUpdatedAt = Date().timeIntervalSince1970 * 1000
        // Mac 上改了开关：立即推送给所有在线手机（双向同步）
        server?.broadcastSettings(sharedSettings)
    }

    var sharedSettings: SharedSettings {
        SharedSettings(paused: paused, blockSensitive: filter.blockSensitive, copyOtp: copyOtp,
                       updatedAt: settingsUpdatedAt)
    }

    /// 收到手机的设置：对方更新就采用对方的，然后把合并结果回传给手机。
    private func handleRemoteSettings(_ remote: SharedSettings, seq: Int, conn: ObjectIdentifier) {
        let merged = sharedSettings.merged(with: remote)
        if merged == remote && remote != sharedSettings {
            applyingRemote = true
            paused = remote.paused
            filter.blockSensitive = remote.blockSensitive
            copyOtp = remote.copyOtp
            settingsUpdatedAt = remote.updatedAt
            applyingRemote = false
            log("已同步手机的设置：同步\(remote.paused ? "暂停" : "开启")、敏感过滤\(remote.blockSensitive ? "开" : "关")、验证码复制\(remote.copyOtp ? "开" : "关")")
            // 转发给其他在线手机
            server.broadcastSettings(merged, except: conn)
        }
        server.sendSettings(merged, seq: seq, to: conn)
    }
    @Published var lastOtp: (code: String, app: String, at: Date)?

    /// 验证码：复制到剪贴板并提示；2 分钟后若剪贴板仍是这个验证码则清除。
    private func handleOtp(_ o: OtpCode, from deviceId: String) -> String {
        if paused { return "paused" }
        if filter.blacklist.contains(o.bundleName) { return "filtered" }
        guard copyOtp else { return "filtered" }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(o.code, forType: .string)
        let change = pb.changeCount
        lastOtp = (o.code, o.appName, Date())
        todayOtp += 1
        notifier.showOtp(code: o.code, app: o.appName, source: sourceLabel(deviceId))
        log("验证码已复制到剪贴板（来自 \(o.appName)，\(o.code.count) 位）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if pb.changeCount == change {
                pb.clearContents()
            }
        }
        return "copied"
    }

    private func touch(_ conn: ObjectIdentifier) {
        lastSync = Date()
        if let d = connectionDevice[conn] { onlineDevices[d] = Date() }
    }

    private func deviceName(_ id: String) -> String { displayName(id) }

    func log(_ text: String) {
        // 日志不写入通知正文
        logs.insert(LogLine(at: Date(), text: text), at: 0)
        if logs.count > 300 { logs.removeLast(logs.count - 300) }
        NSLog("NotiBridge: \(text)")
        Self.appendLogFile(text)
    }

    /// 日志也写一份到 ~/Library/Logs/NotiBridge/notibridge.log（排查问题用，超过 1 MB 换新文件）
    private static let logFile: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotiBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notibridge.log")
    }()

    private static func appendLogFile(_ text: String) {
        let f = logFile
        if let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: f.deletingPathExtension().appendingPathExtension("old.log"))
            try? FileManager.default.moveItem(at: f, to: f.deletingPathExtension().appendingPathExtension("old.log"))
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: f)
        }
    }

    private func saveFilter() {
        if let data = try? JSONEncoder().encode(filter) {
            UserDefaults.standard.set(data, forKey: "filter")
        }
    }

    private static func macId() -> String {
        if let id = UserDefaults.standard.string(forKey: "macId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "macId")
        return id
    }
}
