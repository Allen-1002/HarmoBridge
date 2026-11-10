import AppKit
import SwiftUI

/// Mac 端首次启动引导：欢迎 → 选择使用方式（纯软件 / ESP32）→ 一次性申请所需权限 → [ESP32 检测与刷写] → 添加第一台设备 → 完成。
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var perms = PermissionCenter()
    @State private var step = 0

    private let titles = ["欢迎使用 NotiBridge", "选择使用方式", "授予所需权限", "连接 ESP32 模块", "添加第一台设备", "设置完成"]
    // 步骤编号
    private let stepMode = 1, stepPerms = 2, stepEsp = 3, stepPair = 4

    var body: some View {
        VStack(spacing: 0) {
            // 步骤指示
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: i == step ? 28 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(titles[step]).font(.system(size: 28, weight: .bold))
                    switch step {
                    case 0: welcome
                    case stepMode: modeChoice
                    case stepEsp: esp32Step
                    case stepPerms: permissions
                    case stepPair: pairing
                    default: done
                    }
                }
                .padding(32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                if step > 0 && step < titles.count - 1 {
                    Button("上一步") {
                        step -= 1
                        if step == stepEsp && model.esp32.mode == .software { step -= 1 }
                    }
                }
                Spacer()
                if step == stepPair && !model.hasAnyDevice {
                    Button("稍后添加") { step += 1 }
                }
                Button(nextTitle) { next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == stepPerms && !perms.requiredReady)
                    .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .onAppear { perms.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()
        }
    }

    private var nextTitle: String {
        switch step {
        case 0: return "开始设置"
        case titles.count - 1: return "开始使用"
        default: return "下一步"
        }
    }

    private func next() {
        if step == titles.count - 1 {
            model.finishOnboarding()
            return
        }
        step += 1
        // 纯软件模式跳过 ESP32 步骤
        if step == stepEsp && model.esp32.mode == .software { step += 1 }
    }

    // MARK: - 步骤

    private var modeChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("之后可以在 设置 里更改。手机上的 NotiBridge 不需要做选择。").foregroundStyle(.secondary)
            ForEach(UseMode.allCases) { m in
                KindOption(icon: m == .software ? "bell.badge.fill" : "cpu",
                           color: m == .software ? .blue : .green,
                           title: m == .software ? "纯软件（推荐）" : "ESP32 模式",
                           detail: m.summary,
                           selected: model.esp32.mode == m) {
                    model.esp32.mode = m
                }
            }
        }
    }

    private var esp32Step: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用支持数据传输的 USB 线把 ESP32 模块连接到这台 Mac，插上后会自动检测。第一次使用点“刷写固件”。也可以直接下一步，稍后在侧边栏“ESP32 模块”里完成。")
                .foregroundStyle(.secondary)
            Esp32Panel(esp: model.esp32)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
                Text("把手机上的通知同步到这台 Mac，验证码自动复制到剪贴板。所有数据只在你的手机和 Mac 之间通过局域网加密传输，不经过任何服务器。")
                    .foregroundStyle(.secondary)
            }
            FeatureRow(icon: "bell.badge.fill", color: .blue, title: "通知镜像",
                       text: "微信、短信、邮件等通知出现在 macOS 通知中心，手机上撤销后 Mac 上同步移除")
            FeatureRow(icon: "key.fill", color: .teal, title: "验证码自动复制",
                       text: "只传验证码数字，自动放进剪贴板，2 分钟后清除")
            FeatureRow(icon: "lock.shield.fill", color: .green, title: "端到端加密",
                       text: "配对码 + 校验码确认身份，之后每条消息都加密，未配对的设备无法读取")
            Text("接下来会一次性申请所需的系统权限，每一项都会说明用途。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("带“必需”标记的权限缺少时无法同步通知；其他权限可以稍后在 设置 中开启。")
                .foregroundStyle(.secondary)
            Button {
                perms.requestNotifications()
                perms.requestLocalNetwork()
                perms.requestBluetooth()
            } label: {
                Label("一键申请全部必需和推荐权限", systemImage: "checkmark.shield")
            }
            .controlSize(.large)
            .hbGlassButton()

            PermissionRow(
                icon: "bell.fill", color: .red, title: "通知", tag: "必需",
                reason: "在 macOS 通知中心显示手机转发过来的通知，以及“验证码已复制”的提示。",
                status: perms.notifications,
                action: ("允许", { perms.requestNotifications() }),
                settings: { perms.openSystemSettings("com.apple.Notifications-Settings.extension") })
            PermissionRow(
                icon: "network", color: .blue, title: "本地网络", tag: "必需",
                reason: "在同一 Wi-Fi 下被手机发现（Bonjour），并接收手机发来的加密通知。不会访问互联网上的服务器。",
                status: perms.localNetwork,
                action: ("允许", { perms.requestLocalNetwork() }),
                settings: { perms.openSystemSettings("com.apple.preference.security?Privacy_LocalNetwork") })
            PermissionRow(
                icon: "dot.radiowaves.left.and.right", color: .indigo, title: "蓝牙", tag: "推荐",
                reason: "仅鸿蒙手机需要：鸿蒙系统要求读取通知时绑定一台已配对的蓝牙设备，这台 Mac 可以作为这台设备。安卓手机不需要。",
                status: perms.bluetooth,
                action: ("允许", { perms.requestBluetooth() }),
                settings: { perms.openSystemSettings("com.apple.preference.security?Privacy_Bluetooth") })
            PermissionRow(
                icon: "power", color: .green, title: "登录时启动", tag: "推荐",
                reason: "开机后自动在菜单栏运行，手机通知不会因为忘记打开 App 而漏掉。",
                status: perms.loginItem,
                action: ("开启", { perms.setLoginItem(true) }),
                settings: { perms.openSystemSettings("com.apple.LoginItems-Settings.extension") })
            if model.esp32.mode == .esp32 {
                PermissionRow(
                    icon: "mic.fill", color: .pink, title: "麦克风", tag: "可选",
                    reason: "仅用于 ESP32 模式的通话功能（即将支持），在 Mac 上接打电话时使用。现在可以先不开。",
                    status: perms.microphone,
                    action: ("允许", { perms.requestMicrophone() }),
                    settings: { perms.openSystemSettings("com.apple.preference.security?Privacy_Microphone") })
            }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("之后可以随时在“设备与配对”里继续添加。").foregroundStyle(.secondary)
            AddDeviceFlow(esp: model.esp32, initialKind: model.esp32.mode == .esp32 ? .iphone : .phoneApp)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NotiBridge 会常驻在菜单栏。点菜单栏图标可以查看状态、暂停同步、查看最近的验证码。")
                .foregroundStyle(.secondary)
            CardBox {
                Label("权限可以随时在 设置 > 重新运行首次启动引导 中检查", systemImage: "gearshape")
                Label("关闭主窗口不会退出，通知照常同步", systemImage: "menubar.rectangle")
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PermissionRow: View {
    let icon: String
    let color: Color
    let title: String
    let tag: String
    let reason: String
    let status: PermissionCenter.Status
    let action: (String, () -> Void)
    let settings: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((tag == "必需" ? Color.red : Color.gray).opacity(0.12), in: Capsule())
                        .foregroundStyle(tag == "必需" ? .red : .secondary)
                }
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                statusLabel
                if status != .granted {
                    if status == .denied, let settings {
                        Button("去系统设置", action: settings).controlSize(.small)
                    } else {
                        Button(action.0, action: action.1).controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusLabel: some View {
        let color: Color = status == .granted ? .green : status == .denied ? .red : .secondary
        let icon = status == .granted ? "checkmark.circle.fill" : status == .denied ? "xmark.circle.fill" : "circle.dashed"
        return Label(status.text, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
}
