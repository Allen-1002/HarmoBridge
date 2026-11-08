import Foundation
import HarmoBridgeCore
import UserNotifications

/// macOS 原生通知中心。通知标识 = "hb-" + 手机通知 hashCode，同 id 再次投递即替换，撤销即移除。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let icons = AppIconProvider()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization(_ done: @escaping (Bool, String) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                done(granted, error.map { $0.localizedDescription } ?? "")
            }
        }
    }

    func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    func show(_ n: MirroredNotification) {
        let content = UNMutableNotificationContent()
        let app = n.appName.isEmpty ? n.bundleName : n.appName
        content.title = n.isTest ? "[测试] \(app)" : app
        content.subtitle = n.title
        content.body = n.text
        content.threadIdentifier = n.bundleName
        content.sound = .default
        // 右侧显示原应用图标：Mac 上有对应应用就用它的图标，否则用彩色首字母
        if let att = icons.attachment(bundleName: n.bundleName, appName: app) {
            content.attachments = [att]
        }
        let req = UNNotificationRequest(identifier: identifier(n.id), content: content, trigger: nil)
        center.add(req) { error in
            if let error {
                NSLog("HarmoBridge show notification failed: \(error.localizedDescription)")
            }
        }
    }

    func remove(_ ids: [String]) {
        let list = ids.map(identifier)
        center.removeDeliveredNotifications(withIdentifiers: list)
        center.removePendingNotificationRequests(withIdentifiers: list)
    }

    private func identifier(_ id: String) -> String { "hb-\(id)" }

    func showOtp(code: String, app: String) {
        let content = UNMutableNotificationContent()
        content.title = "验证码 \(code) 已复制"
        content.body = "来自 \(app) · 2 分钟后自动从剪贴板清除"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "hb-otp-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// 来电提醒（通话模块，实验）
    func showCall(number: String) {
        let content = UNMutableNotificationContent()
        content.title = "来电"
        content.body = number
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "hb-call", content: content, trigger: nil))
    }

    func clearCall() {
        center.removeDeliveredNotifications(withIdentifiers: ["hb-call"])
    }

    // App 在前台时也显示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
