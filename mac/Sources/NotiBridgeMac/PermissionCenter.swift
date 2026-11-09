import AppKit
import AVFoundation
import CoreBluetooth
import Foundation
import Network
import Security
import ServiceManagement
import UserNotifications

/// 首次启动引导用的权限中心：查询状态、触发系统授权弹窗、给出用途说明。
@MainActor
final class PermissionCenter: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Status: Equatable {
        case unknown, granted, denied, notDetermined, optional

        var text: String {
            switch self {
            case .granted: return "已允许"
            case .denied: return "已拒绝"
            case .notDetermined: return "未申请"
            case .optional: return "可选"
            case .unknown: return "检测中"
            }
        }
    }

    @Published var notifications: Status = .unknown
    @Published var localNetwork: Status = .notDetermined
    @Published var bluetooth: Status = .unknown
    @Published var loginItem: Status = .unknown
    @Published var microphone: Status = .unknown

    private var central: CBCentralManager?
    private var browser: NWBrowser?

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let st: Status
            switch s.authorizationStatus {
            case .authorized, .provisional: st = .granted
            case .denied: st = .denied
            default: st = .notDetermined
            }
            DispatchQueue.main.async { self.notifications = st }
        }
        switch CBManager.authorization {
        case .allowedAlways: bluetooth = .granted
        case .denied, .restricted: bluetooth = .denied
        default: bluetooth = .notDetermined
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        default: microphone = .optional
        }
        switch SMAppService.mainApp.status {
        case .enabled: loginItem = .granted
        case .requiresApproval: loginItem = .denied
        default: loginItem = .notDetermined
        }
    }

    // MARK: - 申请

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// macOS 没有查询本地网络权限的接口：通过浏览一次 Bonjour 服务触发系统弹窗，并根据结果判断。
    func requestLocalNetwork() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: BridgeServer.serviceType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.localNetwork = .granted
                case let .waiting(err), let .failed(err):
                    if case let .dns(code) = err, code == -65570 { // kDNSServiceErr_PolicyDenied
                        self.localNetwork = .denied
                    }
                default:
                    break
                }
            }
        }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
        }
    }

    func requestBluetooth() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in self.refresh() }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NotiBridge login item: \(error.localizedDescription)")
        }
        refresh()
    }

    func openSystemSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    var requiredReady: Bool {
        notifications == .granted && localNetwork != .denied
    }
}
