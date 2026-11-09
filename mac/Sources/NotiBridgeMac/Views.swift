import AppKit
import NotiBridgeCore
import SwiftUI


// MARK: - Liquid Glass（macOS 26+），旧系统回退为系统材质

@available(macOS 26.0, *)
private func hbMakeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// 玻璃背景。tint 为染色玻璃（旧系统回退为同色渐变）。
    @ViewBuilder
    func hbGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(hbMakeGlass(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint.gradient, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func hbGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// 主窗口各页面：去掉列表/表单自带的不透明底色，透出柔和的彩色背景，玻璃卡片才有层次
    func hbPageBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(AmbientBackground())
    }
}

/// 让相邻的玻璃元素互相融合（macOS 26），旧系统直接显示内容
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 主窗口背景：窗口底色上叠一层很淡的彩色网格渐变
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if #available(macOS 15.0, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [[0, 0], [0.5, 0], [1, 0],
                             [0, 0.5], [0.6, 0.45], [1, 0.5],
                             [0, 1], [0.5, 1], [1, 1]],
                    colors: [.indigo, .blue, .cyan,
                             .purple, .clear, .teal,
                             .blue, .mint, .indigo])
                    .opacity(scheme == .dark ? 0.28 : 0.16)
            } else {
                Theme.heroGradient.opacity(scheme == .dark ? 0.22 : 0.12)
            }
        }
        .ignoresSafeArea()
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
            .shadow(color: Theme.avatarColor(key).opacity(0.25), radius: 3, y: 1)
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
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 状态点
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.8), radius: 3)
    }
}

/// 卡片容器
struct CardBox<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension AppModel {
    var statusColor: Color {
        if paused { return .orange }
        if isPhoneOnline { return .green }
        return pairedDevices.isEmpty ? .gray : .blue
    }

    /// 主状态卡片的玻璃染色
    var heroTint: Color {
        if pairedDevices.isEmpty { return Color.gray.opacity(0.55) }
        if paused { return Color.orange.opacity(0.75) }
        return Color(red: 0.16, green: 0.42, blue: 0.95).opacity(0.8)
    }

    var headline: String {
        if pairedDevices.isEmpty { return "尚未配对手机" }
        return paused ? "同步已暂停" : "通知同步中"
    }
}

// MARK: - 菜单栏弹窗

struct StatusMenu: View {
    @EnvironmentObject var model: AppModel
    var openMain: () -> Void = {}

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                header
                hero
                CallControls()
                otpCard
                if let pin = model.pairingPin {
                    PairingPanel(pin: pin, sas: model.pairingSas)
                }
                recent
                updateBadge
                footer
            }
            .padding(16)
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("NotiBridge").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    StatusDot(color: model.statusColor)
                    Text(model.phoneStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: openMain) {
                Image(systemName: "macwindow")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hbGlass(Circle(), interactive: true)
            .help("打开主窗口")
        }
    }

    private var hero: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline).font(.system(size: 17, weight: .bold))
                Text("今日显示 \(model.todayShown) 条 · 验证码 \(model.todayOtp) 个")
                    .font(.caption).opacity(0.85)
            }
            .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.white.opacity(0.4))
                .disabled(model.pairedDevices.isEmpty)
        }
        .padding(16)
        .hbGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), tint: model.heroTint)
    }

    @ViewBuilder
    private var otpCard: some View {
        if let otp = model.lastOtp, Date().timeIntervalSince(otp.at) < 120 {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(.blue)
                    .frame(width: 30, height: 30)
                    .background(Color.blue.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(otp.code).font(.system(size: 17, weight: .bold, design: .monospaced))
                    Text("来自 \(otp.app) · 已复制").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("再次复制") { model.copyAgain(otp.code) }.controlSize(.small).hbGlassButton()
            }
            .padding(12)
            .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近通知").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                if model.records.isEmpty {
                    Text("暂无通知").font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                ForEach(model.records.prefix(5)) { r in
                    HStack(spacing: 10) {
                        AppAvatar(name: r.notification.appName, key: r.notification.bundleName, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.notification.appName).font(.callout.weight(.medium)).lineLimit(1)
                            if model.showContentInList {
                                Text(r.notification.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(r.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                            ResultBadge(result: r.result)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)
            .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// 关闭了“自动下载并安装”时，有新版本就在弹窗里提示
    @ViewBuilder
    private var updateBadge: some View {
        let u = model.updater
        if let r = u.available, !u.autoInstall || u.phase == .failed || u.isBusy {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                    .frame(width: 30, height: 30)
                    .background(Color.green.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("有新版本 \(r.version)").font(.callout.weight(.semibold))
                    Text(u.isBusy ? u.status : "当前 \(u.currentVersion)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("立即更新") { u.installAvailable() }.controlSize(.small).hbGlassButton()
                    .disabled(u.isBusy)
            }
            .padding(12)
            .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.pairingPin == nil ? model.openPairing() : model.cancelPairing()
            } label: {
                Label(model.pairingPin == nil ? "配对新手机" : "取消配对",
                      systemImage: model.pairingPin == nil ? "plus" : "xmark")
                    .frame(maxWidth: .infinity)
            }
            .hbGlassButton()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power").frame(maxWidth: .infinity)
            }
            .hbGlassButton()
        }
        .controlSize(.large)
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
        .padding(14)
        .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                Button("接听") { model.answerCall() }.hbGlassButton(prominent: true).tint(.green)
                Button("拒接") { model.hangUpCall() }.hbGlassButton(prominent: true).tint(.red)
            }
            .padding(12)
            .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        case let .active(n), let .dialing(n):
            HStack {
                Image(systemName: "phone.fill").foregroundStyle(.green)
                Text(model.callState.label)
                Spacer()
                Button("挂断") { model.hangUpCall() }.hbGlassButton(prominent: true).tint(.red)
            }
            .padding(12)
            .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .background(AmbientBackground())
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
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
        .frame(minWidth: 780, minHeight: 540)
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 16) {
                VStack(alignment: .leading, spacing: 20) {
                    hero

                    // 统计
                    HStack(spacing: 12) {
                        StatCard(value: model.todayShown, label: "今日已显示", icon: "bell.fill", color: .blue)
                        StatCard(value: model.todayOtp, label: "验证码已复制", icon: "key.fill", color: .teal)
                        StatCard(value: model.todayFiltered, label: "已过滤", icon: "line.3.horizontal.decrease", color: .orange)
                        StatCard(value: model.pairedDevices.count, label: "已配对手机", icon: "iphone", color: .purple)
                    }

                    // 快捷操作
                    SectionTitle("快捷操作")
                    HStack(spacing: 12) {
                        QuickAction(title: "配对新手机", icon: "plus.circle.fill", color: .blue) {
                            model.openPairing()
                            selection = .devices
                        }
                        QuickAction(title: "打开蓝牙设置", icon: "dot.radiowaves.left.and.right", color: .indigo) {
                            model.openBluetoothSettings()
                        }
                        QuickAction(title: "测试 Mac 通知", icon: "bell.and.waves.left.and.right", color: .pink) {
                            model.sendLocalTestNotification()
                        }
                    }

                    // 最近通知
                    HStack {
                        SectionTitle("最近通知")
                        Spacer()
                        Button("查看全部") { selection = .records }.hbGlassButton().controlSize(.small)
                    }
                    CardBox {
                        if model.records.isEmpty {
                            Text("还没有收到手机通知").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                        }
                        ForEach(model.records.prefix(6)) { r in
                            RecordRow(record: r, showContent: model.showContentInList)
                            if r.id != model.records.prefix(6).last?.id { Divider().opacity(0.5) }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .hbPageBackground()
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.headline).font(.system(size: 26, weight: .bold))
                HStack(spacing: 8) {
                    HeroChip(icon: "iphone", text: model.phoneStatusText)
                    HeroChip(icon: "network", text: model.listening)
                }
            }
            .foregroundStyle(.white)
            Spacer()
            Toggle("同步", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
                .tint(.white.opacity(0.4))
                .disabled(model.pairedDevices.isEmpty)
        }
        .padding(24)
        .hbGlass(RoundedRectangle(cornerRadius: 26, style: .continuous), tint: model.heroTint)
    }
}

/// 主状态卡片里的小标签
struct HeroChip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.18), in: Capsule())
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.title3.weight(.semibold))
    }
}

struct StatCard: View {
    let value: Int
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hbGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct QuickAction: View {
    let title: String
    let icon: String
    var color: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(color)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hbGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
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
        .hbPageBackground()
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
                Text("手机需要和 Mac 蓝牙配对一次，作为系统要求的通知订阅设备。打开 Mac 的蓝牙设置页面并保持打开，手机 NotiBridge 的“蓝牙设备 > 扫描”就能找到这台 Mac。")
            }
            Section("局域网") {
                LabeledContent("服务", value: model.listening)
                LabeledContent("本机地址", value: model.localAddresses().joined(separator: "\n"))
            }
        }
        .formStyle(.grouped)
        .hbPageBackground()
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false
    @State private var confirmUninstall = false

    private static let deletedItems = "将删除：钥匙串中所有已配对手机的密钥、这台 Mac 的设备标识、全部设置（过滤规则、同步开关、使用方式等）、应用图标缓存、登录时启动项，以及通知中心里的 NotiBridge 通知。所有手机都需要重新配对。"

    var body: some View {
        Form {
            Section {
                Toggle("同步通知", isOn: Binding(get: { !model.paused }, set: { model.paused = !$0 }))
                Toggle("验证码自动复制到剪贴板", isOn: $model.copyOtp)
                Toggle("不转发银行、支付类通知", isOn: $model.filter.blockSensitive)
                Toggle("在列表中显示通知内容", isOn: $model.showContentInList)
            } header: {
                Text("同步")
            } footer: {
                Text("前三项与手机自动保持一致：在任意一端修改，另一端会在下次连接时同步（手机打开 NotiBridge 或来新通知时）。")
            }
            Section {
                Picker("使用方式", selection: Binding(get: { model.esp32.mode }, set: { model.esp32.mode = $0 })) {
                    ForEach(UseMode.allCases) { m in Text(m.title).tag(m) }
                }
                if model.esp32.mode == .esp32 {
                    Esp32Panel(esp: model.esp32)
                }
            } header: {
                Text("ESP32 通话模块")
            } footer: {
                Text(model.esp32.mode == .software ? UseMode.software.detail : "通话固件尚在开发中，目前只能检测硬件和固件。")
            }
            Section("系统") {
                Toggle("登录时自动启动", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                LabeledContent("macOS 通知权限", value: model.notificationsAllowed)
                Button("发送一条测试通知（不经过手机）") { model.sendLocalTestNotification() }
                Button("重新运行首次启动引导（检查权限）") { model.restartOnboarding() }
            }
            UpdateSection(updater: model.updater)
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                Text("通知只在你的手机和这台 Mac 之间加密传输，不经过任何服务器。检查更新时只访问 GitHub（api.github.com），不发送任何个人数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("清除所有数据并重新开始…", role: .destructive) { confirmReset = true }
                Button("卸载 NotiBridge…", role: .destructive) { confirmUninstall = true }
            } header: {
                Text("卸载与重置")
            } footer: {
                Text("“清除所有数据”会让 NotiBridge 回到刚安装时的状态并重新打开；“卸载”会在清除数据后把应用移到废纸篓。手机上的配对需要在手机端另外移除。")
            }
        }
        .formStyle(.grouped)
        .hbPageBackground()
        .confirmationDialog("清除所有数据并重新开始？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("清除并重新开始", role: .destructive) { model.resetAndRelaunch() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.deletedItems + "\n\nNotiBridge 会自动重新打开并进入首次启动引导。")
        }
        .confirmationDialog("卸载 NotiBridge？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("清除数据并卸载", role: .destructive) { model.uninstallApp() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.deletedItems + "\n\n然后 NotiBridge.app 会被移到废纸篓并退出。macOS 通知、蓝牙等权限记录由系统管理，可在“系统设置”中自行移除。")
        }
    }
}

struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            LabeledContent("当前版本", value: updater.currentVersion)
            LabeledContent("最新版本", value: updater.latestVersion ?? "未知")
            Toggle("自动检查更新", isOn: $updater.autoCheck)
            Toggle("自动下载并安装", isOn: $updater.autoInstall)
            VStack(alignment: .leading, spacing: 6) {
                Text(updater.status)
                    .foregroundStyle(updater.phase == .failed ? .red : .secondary)
                    .textSelection(.enabled)
                if let p = updater.progress {
                    ProgressView(value: p)
                }
            }
            if !updater.notes.isEmpty, updater.available != nil {
                Text(updater.notes).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("检查更新") { updater.check(manual: true) }
                    .disabled(updater.isBusy)
                if let r = updater.available {
                    Button("立即更新到 \(r.version)") { updater.installAvailable() }
                        .disabled(updater.isBusy)
                    Button("查看发布页") { NSWorkspace.shared.open(r.htmlURL) }
                }
            }
        } header: {
            Text("软件更新")
        } footer: {
            Text("从 GitHub Releases 下载新版，校验 SHA256 和签名后自动替换并重新打开。启动 30 秒后检查一次，之后每 6 小时检查一次；正在配对手机时不会更新。")
        }
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
                Toggle("不转发银行、支付类通知", isOn: $model.filter.blockSensitive)
            } footer: {
                Text("验证码会单独以“只发验证码”的方式复制到剪贴板，不受这里影响。暂停同步、验证码复制和这一项会与手机自动保持一致。")
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
        .hbPageBackground()
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
        .hbPageBackground()
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
        .hbPageBackground()
        .onAppear { if model.btDevices.isEmpty { model.refreshBTDevices() } }
    }
}
