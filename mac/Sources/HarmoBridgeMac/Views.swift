import AppKit
import HarmoBridgeCore
import SwiftUI


// MARK: - Liquid Glass（macOS 26+），旧系统回退为系统材质

extension View {
    @ViewBuilder
    func hbGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func hbGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

// MARK: - 设计元素

enum Theme {
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.22, green: 0.29, blue: 0.67), Color(red: 0.12, green: 0.53, blue: 0.90),
                 Color(red: 0.0, green: 0.75, blue: 0.65)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let avatarColors: [Color] = [.blue, .green, .orange, .red, .purple, .teal, .pink, .indigo]

    static func avatarColor(_ key: String) -> Color {
        var h = 0
        for u in key.unicodeScalars { h = (h &* 31 &+ Int(u.value)) % 997 }
        return avatarColors[abs(h) % avatarColors.count]
    }
}

/// 应用首字母头像
struct AppAvatar: View {
    let name: String
    let key: String
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.avatarColor(key).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// 结果标签
struct ResultBadge: View {
    let result: String

    var body: some View {
        let (text, color): (String, Color) = {
            switch result {
            case "shown": return ("已显示", .green)
            case "duplicate": return ("重复", .gray)
            case "filtered": return ("已过滤", .orange)
            case "paused": return ("已暂停", .gray)
            case "copied": return ("已复制", .blue)
            default: return (result, .gray)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 状态点
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 3))
    }
}

/// 卡片容器
struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension AppModel {
    var statusColor: Color {
        if paused { return .orange }
        if isPhoneOnline { return .green }
        return pairedDevices.isEmpty ? .gray : .blue
    }

    var headline: String {
        if pairedDevices.isEmpty { return "尚未配对手机" }
        return paused ? "同步已暂停" : "通知同步中"
    }
}

// MARK: - 菜单栏弹窗

struct StatusMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HarmoBridge").font(.headline)
                    HStack(spacing: 6) {
                        StatusDot(color: model.statusColor)
                        Text(model.phoneStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    openMain()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("打开主窗口")
            }

            // 同步开关
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.headline).font(.system(size: 15, weight: .semibold))
                    Text("今日显示 \(model.todayShown) 条 · 验证码 \(model.todayOtp) 个")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.white.opacity(0.35))
                    .disabled(model.pairedDevices.isEmpty)
            }
            .padding(14)
            .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            CallControls()

            if let otp = model.lastOtp, Date().timeIntervalSince(otp.at) < 120 {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(otp.code).font(.system(size: 17, weight: .bold, design: .monospaced))
                        Text("来自 \(otp.app) · 已复制").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("再次复制") { model.copyAgain(otp.code) }.controlSize(.small).hbGlassButton()
                }
                .padding(10)
                .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let pin = model.pairingPin {
                PairingPanel(pin: pin, sas: model.pairingSas)
            }

            // 最近通知
            VStack(alignment: .leading, spacing: 6) {
                Text("最近通知").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.records.isEmpty {
                    Text("暂无通知").font(.callout).foregroundStyle(.tertiary).padding(.vertical, 8)
                }
                ForEach(model.records.prefix(5)) { r in
                    HStack(spacing: 10) {
                        AppAvatar(name: r.notification.appName, key: r.notification.bundleName, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.notification.appName).font(.callout).lineLimit(1)
                            if model.showContentInList {
                                Text(r.notification.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        ResultBadge(result: r.result)
                        Text(r.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()
            HStack {
                Button(model.pairingPin == nil ? "配对新手机" : "取消配对") {
                    model.pairingPin == nil ? model.openPairing() : model.cancelPairing()
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PairingPanel: View {
    let pin: String
    let sas: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("在手机上输入配对码", systemImage: "iphone.and.arrow.forward").font(.caption)
            Text(pin.map { String($0) }.joined(separator: " "))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            if let sas {
                Label("校验码 \(sas)：必须与手机上显示的一致", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("2 分钟内有效").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 菜单栏中的通话快捷操作，仅在有来电或通话时显示
struct CallControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.callState {
        case let .incoming(n):
            HStack {
                Image(systemName: "phone.arrow.down.left").foregroundStyle(.green)
                Text("来电 \(n)").bold()
                Spacer()
                Button("接听") { model.answerCall() }
                Button("拒接") { model.hangUpCall() }
            }
        case let .active(n), let .dialing(n):
            HStack {
                Image(systemName: "phone.fill").foregroundStyle(.green)
                Text(model.callState.label)
                Spacer()
                Button("挂断") { model.hangUpCall() }
            }
            .help(n)
        default:
            EmptyView()
        }
    }
}

// MARK: - 主窗口

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "概览"
    case records = "通知记录"
    case devices = "设备与配对"
    case filters = "过滤规则"
    case phone = "电话（实验）"
    case logs = "日志"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .records: return "bell.badge"
        case .devices: return "iphone.and.arrow.forward"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .phone: return "phone"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        if model.onboarded {
            mainContent
        } else {
            OnboardingView()
                .frame(minWidth: 760, minHeight: 600)
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(selection: $selection)
                case .records: RecordsView()
                case .devices: DevicesView()
                case .filters: FilterTab()
                case .phone: PhoneTab()
                case .logs: LogTab()
                case .settings: SettingsView()
                }
            }
            .navigationTitle((selection ?? .overview).rawValue)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 主状态卡片
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.headline).font(.system(size: 24, weight: .bold))
                        Text("手机：\(model.phoneStatusText)").foregroundStyle(.white.opacity(0.85))
                        Text(model.listening).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Toggle("同步", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                        .toggleStyle(.switch)
                        .tint(.white.opacity(0.35))
                        .foregroundStyle(.white)
                        .disabled(model.pairedDevices.isEmpty)
                }
                .padding(20)
                .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // 统计
                HStack(spacing: 12) {
                    StatCard(value: model.todayShown, label: "今日已显示", icon: "bell.fill", color: .blue)
                    StatCard(value: model.todayOtp, label: "验证码已复制", icon: "key.fill", color: .teal)
                    StatCard(value: model.todayFiltered, label: "已过滤", icon: "line.3.horizontal.decrease", color: .orange)
                    StatCard(value: model.pairedDevices.count, label: "已配对手机", icon: "iphone", color: .purple)
                }

                // 快捷操作
                Text("快捷操作").font(.headline)
                HStack(spacing: 12) {
                    QuickAction(title: "配对新手机", icon: "plus.circle.fill") {
                        model.openPairing()
                        selection = .devices
                    }
                    QuickAction(title: "打开蓝牙设置", icon: "dot.radiowaves.left.and.right") {
                        model.openBluetoothSettings()
                    }
                    QuickAction(title: "测试 Mac 通知", icon: "bell.and.waves.left.and.right") {
                        model.sendLocalTestNotification()
                    }
                }

                // 最近通知
                HStack {
                    Text("最近通知").font(.headline)
                    Spacer()
                    Button("查看全部") { selection = .records }.buttonStyle(.link)
                }
                CardBox {
                    if model.records.isEmpty {
                        Text("还没有收到手机通知").foregroundStyle(.secondary)
                    }
                    ForEach(model.records.prefix(6)) { r in
                        RecordRow(record: r, showContent: model.showContentInList)
                        if r.id != model.records.prefix(6).last?.id { Divider() }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct StatCard: View {
    let value: Int
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            Text("\(value)").font(.system(size: 26, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct QuickAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
                Text(title)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RecordRow: View {
    let record: ReceivedRecord
    let showContent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppAvatar(name: record.notification.appName, key: record.notification.bundleName, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.notification.appName).font(.callout.weight(.semibold))
                    if record.notification.isTest {
                        Text("测试").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ResultBadge(result: record.result)
                    Text(record.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if showContent {
                    Text(record.notification.title).font(.callout).lineLimit(1)
                    Text(record.notification.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(record.notification.bundleName).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct RecordsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    var filtered: [ReceivedRecord] {
        guard !query.isEmpty else { return model.records }
        return model.records.filter {
            $0.notification.appName.localizedCaseInsensitiveContains(query) ||
                $0.notification.bundleName.localizedCaseInsensitiveContains(query) ||
                (model.showContentInList && ($0.notification.title.localizedCaseInsensitiveContains(query) ||
                    $0.notification.text.localizedCaseInsensitiveContains(query)))
        }
    }

    var body: some View {
        List(filtered) { r in
            RecordRow(record: r, showContent: model.showContentInList).padding(.vertical, 4)
        }
        .overlay {
            if model.records.isEmpty {
                ContentUnavailableView("还没有通知", systemImage: "bell.slash",
                                       description: Text("手机收到通知后会显示在这里，记录只保存在内存中"))
            }
        }
        .searchable(text: $query, prompt: "搜索应用")
        .toolbar {
            Toggle(isOn: $model.showContentInList) {
                Label("显示内容", systemImage: model.showContentInList ? "eye" : "eye.slash")
            }
        }
    }
}

struct DevicesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("已配对的手机") {
                if model.pairedDevices.isEmpty {
                    Text("还没有配对的手机").foregroundStyle(.secondary)
                }
                ForEach(model.pairedDevices) { d in
                    HStack {
                        Image(systemName: "iphone").font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text(model.onlineDevices[d.id] != nil ? "已连接" : model.phoneStatusText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消配对", role: .destructive) { model.unpair(d) }
                    }
                }
                if let pin = model.pairingPin {
                    PairingPanel(pin: pin, sas: model.pairingSas)
                    Button("取消") { model.cancelPairing() }
                } else {
                    Button {
                        model.openPairing()
                    } label: {
                        Label("配对新手机", systemImage: "plus")
                    }
                }
            }
            Section {
                LabeledContent("Mac 蓝牙名称", value: model.macBluetoothName)
                Button {
                    model.openBluetoothSettings()
                } label: {
                    Label("打开 Mac 蓝牙设置", systemImage: "dot.radiowaves.left.and.right")
                }
            } header: {
                Text("蓝牙")
            } footer: {
                Text("手机需要和 Mac 蓝牙配对一次，作为系统要求的通知订阅设备。打开 Mac 的蓝牙设置页面并保持打开，手机 HarmoBridge 的“蓝牙设备 > 扫描”就能找到这台 Mac。")
            }
            Section("局域网") {
                LabeledContent("服务", value: model.listening)
                LabeledContent("本机地址", value: model.localAddresses().joined(separator: "\n"))
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("同步") {
                Toggle("同步通知", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                Toggle("验证码自动复制到剪贴板", isOn: $model.copyOtp)
                Toggle("在列表中显示通知内容", isOn: $model.showContentInList)
            }
            Section("系统") {
                Toggle("登录时自动启动", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                LabeledContent("macOS 通知权限", value: model.notificationsAllowed)
                Button("发送一条测试通知（不经过手机）") { model.sendLocalTestNotification() }
                Button("重新运行首次启动引导（检查权限）") { model.restartOnboarding() }
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                Text("所有数据只在你的手机和这台 Mac 之间加密传输，不连接任何服务器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct FilterTab: View {
    @EnvironmentObject var model: AppModel
    @State private var newBundle = ""

    var body: some View {
        Form {
            Section {
                Picker("模式", selection: $model.filter.mode) {
                    Text("全部转发（黑名单除外）").tag(SyncFilter.Mode.allExceptBlacklist)
                    Text("仅白名单").tag(SyncFilter.Mode.whitelistOnly)
                }
                Toggle("拦截验证码、银行、支付等敏感通知全文", isOn: $model.filter.blockSensitive)
            } footer: {
                Text("验证码会单独以“只发验证码”的方式复制到剪贴板，不受这里影响。")
            }
            Section("添加应用") {
                HStack {
                    TextField("应用包名，如 com.tencent.wechat", text: $newBundle)
                    Button("加入白名单") { add(to: \.whitelist) }
                    Button("加入黑名单") { add(to: \.blacklist) }
                }
            }
            Section("白名单") { bundleList(\.whitelist) }
            Section("黑名单") { bundleList(\.blacklist) }
            Section("最近出现的应用") {
                ForEach(Array(Set(model.records.map { $0.notification.bundleName })).sorted(), id: \.self) { b in
                    HStack {
                        Text(b)
                        Spacer()
                        Button("白名单") { model.filter.whitelist.insert(b) }
                        Button("黑名单") { model.filter.blacklist.insert(b) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add(to path: WritableKeyPath<SyncFilter, Set<String>>) {
        let b = newBundle.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        model.filter[keyPath: path].insert(b)
        newBundle = ""
    }

    @ViewBuilder
    private func bundleList(_ path: WritableKeyPath<SyncFilter, Set<String>>) -> some View {
        if model.filter[keyPath: path].isEmpty {
            Text("无").foregroundStyle(.tertiary)
        }
        ForEach(Array(model.filter[keyPath: path]).sorted(), id: \.self) { b in
            HStack {
                Text(b)
                Spacer()
                Button("移除") { model.filter[keyPath: path].remove(b) }
            }
        }
    }
}

struct LogTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(model.logs) { l in
            HStack(alignment: .top) {
                Text(l.at.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(l.text).font(.caption).textSelection(.enabled)
            }
        }
    }
}

struct PhoneTab: View {
    @EnvironmentObject var model: AppModel
    @State private var number = ""

    var body: some View {
        Form {
            Section {
                Text("实验功能：Mac 作为蓝牙免提设备（HFP）连接手机，不需要 ESP32。手机需先与 Mac 蓝牙配对。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("手机", selection: $model.selectedBT) {
                        Text("请选择").tag("")
                        ForEach(model.btDevices) { d in
                            Text("\(d.name)  \(d.id)").tag(d.id)
                        }
                    }
                    Button("刷新") { model.refreshBTDevices() }
                }
                HStack {
                    Button("连接免提") { model.connectCall() }
                    Button("断开") { model.disconnectCall() }
                }
                LabeledContent("状态", value: model.callState.label)
            }
            Section("通话") {
                HStack {
                    Button("接听") { model.answerCall() }
                    Button("挂断 / 拒接") { model.hangUpCall() }
                }
                HStack {
                    TextField("号码", text: $number)
                    Button("拨号") { model.dial(number) }
                }
                HStack {
                    Button("音频切到 Mac") { model.audioToMac() }
                    Button("音频切回手机") { model.audioToPhone() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if model.btDevices.isEmpty { model.refreshBTDevices() } }
    }
}
