import AppKit
import NotiBridgeCore
import SwiftUI

// MARK: - 设备与配对

extension AppModel {
    /// ESP32 模式下经 ESP32 配对的 iPhone（纯软件模式不显示）
    var iphoneDevices: [PairedIphone] { esp32.mode == .esp32 ? esp32.iphones : [] }
    /// 手机 App + iPhone 总数
    var deviceCount: Int { pairedDevices.count + iphoneDevices.count }
    var hasAnyDevice: Bool { deviceCount > 0 }

    /// 打开“添加设备”弹窗（kind 为 nil 时先选择设备类型）
    func openAddDevice(_ kind: AddDeviceKind? = nil) {
        addDeviceKind = kind
        showAddDevice = true
    }
}

/// 设备与配对：所有手机（安卓 / 鸿蒙 App，以及经 ESP32 的 iPhone）+ 添加设备入口
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    var openEsp32: () -> Void = {}
    @State private var renaming: PairingStore.Device?
    @State private var newName = ""
    @State private var removingPhone: PairingStore.Device?
    @State private var removingIphone: PairedIphone?

    var body: some View {
        Form {
            Section {
                if !model.hasAnyDevice {
                    Text("还没有设备。点“添加设备”配对安卓、鸿蒙手机或 iPhone。").foregroundStyle(.secondary)
                }
                ForEach(model.pairedDevices) { d in phoneRow(d) }
                ForEach(model.iphoneDevices, id: \.id) { p in iphoneRow(p) }
                Button {
                    model.openAddDevice()
                } label: {
                    Label("添加设备", systemImage: "plus")
                }
            } header: {
                Text("我的设备")
            } footer: {
                Text(model.esp32.mode == .esp32
                     ? "安卓、鸿蒙手机通过局域网同步通知；iPhone 通过 ESP32 模块同步通知。通话功能即将支持。"
                     : "纯软件模式支持安卓、鸿蒙手机的通知。想同步 iPhone 通知或在电脑上接打电话，请在“ESP32 模块”里启用 ESP32 模式。")
            }
        }
        .formStyle(.grouped)
        .hbPageBackground()
        .alert("给手机改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("保存") {
                if let d = renaming { model.rename(d, to: newName) }
                renaming = nil
            }
            if let d = renaming, model.displayName(d.id) != d.name {
                Button("恢复原名") {
                    model.rename(d, to: "")
                    renaming = nil
                }
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("名字只保存在这台电脑上。配对了多台设备时，通知会用这个名字标出来源。")
        }
        .confirmationDialog("移除“\(removingPhone.map { model.displayName($0.id) } ?? "")”？",
                            isPresented: Binding(get: { removingPhone != nil }, set: { if !$0 { removingPhone = nil } }),
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let d = removingPhone { model.unpair(d) }
                removingPhone = nil
            }
            Button("取消", role: .cancel) { removingPhone = nil }
        } message: {
            Text("这台电脑会删除和它的配对密钥。手机在线时会同步删除；不在线时，手机下次连接会提示这台电脑已移除，需要在手机上手动删除。之后要再用需要重新配对。")
        }
        .confirmationDialog("移除“\(removingIphone.map(iphoneName) ?? "")”？",
                            isPresented: Binding(get: { removingIphone != nil }, set: { if !$0 { removingIphone = nil } }),
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let p = removingIphone { model.esp32.forgetIphone(p.id) }
                removingIphone = nil
            }
            Button("取消", role: .cancel) { removingIphone = nil }
        } message: {
            Text("ESP32 会删除和这台 iPhone 的蓝牙配对。也请在 iPhone 的「设置 › 蓝牙」里点 NotiBridge 右边的 ⓘ，选“忽略此设备”。之后要再用需要重新配对。")
        }
    }

    private func phoneRow(_ d: PairingStore.Device) -> some View {
        let online = model.onlineDevices[d.id] != nil
        let custom = model.displayName(d.id) != d.name
        return DeviceRow(
            icon: "iphone", color: .accentColor,
            name: model.displayName(d.id),
            detail: (custom ? "\(d.name) · " : "") + (online ? "已连接" : "待命（有通知时自动连接）"),
            notifyReady: true,
            actions: {
                Button("改名") {
                    newName = model.displayName(d.id)
                    renaming = d
                }
                Button("移除", role: .destructive) { removingPhone = d }
            })
    }

    private func iphoneRow(_ p: PairedIphone) -> some View {
        DeviceRow(
            icon: "apple.logo", color: .primary,
            name: iphoneName(p),
            detail: "经 ESP32 · " + iphoneStatus(p),
            notifyReady: p.ancsReady,
            actions: {
                Button("移除", role: .destructive) { removingIphone = p }
            })
    }
}

func iphoneName(_ p: PairedIphone) -> String { p.name.isEmpty ? "iPhone" : p.name }

func iphoneStatus(_ p: PairedIphone) -> String {
    if p.ancsReady { return "通知已就绪" }
    if p.connected { return "已连接，等待 iPhone 允许共享通知" }
    return "未连接（iPhone 在附近时会自动连接）"
}

/// 设备列表中的一行：名字、状态，以及“通知 / 通话”两项能力
struct DeviceRow<Actions: View>: View {
    let icon: String
    let color: Color
    let name: String
    let detail: String
    let notifyReady: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    CapabilityChip(title: "通知", state: notifyReady ? "✓" : "未就绪", on: notifyReady)
                    CapabilityChip(title: "通话", state: "即将支持", on: false)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 2)
    }
}

struct CapabilityChip: View {
    let title: String
    let state: String
    let on: Bool

    var body: some View {
        Text("\(title) \(state)")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((on ? Color.green : Color.gray).opacity(0.14), in: Capsule())
            .foregroundStyle(on ? .green : .secondary)
    }
}

// MARK: - 添加设备

enum AddDeviceKind {
    case phoneApp
    case iphone
}

/// “添加设备”弹窗（概览、设备与配对、菜单栏都打开它）
struct AddDeviceSheet: View {
    @EnvironmentObject var model: AppModel
    var openEsp32: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("添加设备").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            AddDeviceFlow(esp: model.esp32, onOpenEsp32: {
                dismiss()
                openEsp32()
            }, initialKind: model.addDeviceKind)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 460)
    }
}

/// 添加设备流程：先选设备类型，再按类型配对。弹窗和首次引导共用。
struct AddDeviceFlow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var esp: Esp32Manager
    /// 跳到 ESP32 模块页（首次引导里为 nil：ESP32 步骤就在前一步）
    var onOpenEsp32: (() -> Void)?
    /// 预先选好的类型（首次引导 ESP32 模式默认 iPhone）
    var initialKind: AddDeviceKind?

    @State private var kind: AddDeviceKind?
    @State private var startPhoneIds: Set<String> = []
    @State private var startIphoneIds: Set<String> = []
    @State private var iphoneDeadline: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case nil: chooser
            case .phoneApp: phoneAppFlow
            case .iphone: iphoneFlow
            }
        }
        .onAppear {
            if kind == nil, let initialKind { choose(initialKind) }
        }
        .onDisappear { model.cancelPairing() }
    }

    // MARK: 选择类型

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("要添加哪种手机？").foregroundStyle(.secondary)
            KindOption(icon: "iphone", color: .blue, title: "安卓 / 鸿蒙手机",
                       detail: "在手机上安装 NotiBridge App，同一 Wi-Fi 下输入配对码。", enabled: true) {
                choose(.phoneApp)
            }
            KindOption(icon: "apple.logo", color: .primary, title: "iPhone",
                       detail: esp.mode == .esp32
                           ? "不用装 App：iPhone 在蓝牙设置里和 ESP32 模块配对。"
                           : "需要 ESP32 模块。当前是纯软件模式，选择后可以启用 ESP32 模式。",
                       enabled: esp.mode == .esp32) {
                choose(.iphone)
            }
        }
    }

    private func choose(_ k: AddDeviceKind) {
        kind = k
        switch k {
        case .phoneApp:
            startPhoneIds = Set(model.pairedDevices.map(\.id))
            if model.pairingPin == nil { model.openPairing() }
        case .iphone:
            startIphonePairingIfReady()
        }
    }

    private var backToChooser: some View {
        Button {
            model.cancelPairing()
            iphoneDeadline = nil
            kind = nil
        } label: {
            Label("换一种设备", systemImage: "chevron.left")
        }
        .buttonStyle(.link)
    }

    // MARK: 安卓 / 鸿蒙

    private var newPhone: PairingStore.Device? {
        model.pairedDevices.first { !startPhoneIds.contains($0.id) }
    }

    @ViewBuilder private var phoneAppFlow: some View {
        backToChooser
        if let d = newPhone {
            CardBox {
                Label("已添加：\(model.displayName(d.id))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Text("这台手机的通知会同步到这台电脑。").foregroundStyle(.secondary)
                Button("再添加一台") { choose(.phoneApp) }
            }
        } else {
            StepText(n: 1, text: "在手机上打开 NotiBridge，点“添加电脑”，选择“\(model.macBluetoothName)”。手机和电脑需要在同一个 Wi-Fi（局域网）下。")
            StepText(n: 2, text: "在手机上输入下面的配对码，然后核对两边显示的校验码一致。")
            if let pin = model.pairingPin {
                PairingPanel(pin: pin, sas: model.pairingSas)
            } else {
                HStack {
                    Text("配对码已过期").foregroundStyle(.secondary)
                    Button("重新生成配对码") { model.openPairing() }
                }
            }
            DisclosureGroup("鸿蒙手机还需要绑定一台蓝牙设备（安卓不需要）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("鸿蒙系统要求读取通知时绑定一台已配对的蓝牙设备，通知本身仍走局域网。手机已经绑定过其他电脑就不用再做。否则打开 Mac 的蓝牙设置并保持页面打开，在手机 NotiBridge 的“蓝牙设备 › 扫描”里选择“\(model.macBluetoothName)”。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开 Mac 蓝牙设置") { model.openBluetoothSettings() }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: iPhone（经 ESP32）

    /// ESP32 是否可以接受新 iPhone：ESP32 模式、已连接固件
    private var espReady: Bool { esp.mode == .esp32 && esp.link != nil }

    private var newIphone: PairedIphone? {
        esp.iphones.first { !startIphoneIds.contains($0.id) }
    }

    private func startIphonePairingIfReady() {
        guard espReady else { return }
        startIphoneIds = Set(esp.iphones.map(\.id))
        esp.pairNewIphone()
        iphoneDeadline = Date().addingTimeInterval(180)
    }

    @ViewBuilder private var iphoneFlow: some View {
        backToChooser
        if esp.mode != .esp32 {
            CardBox {
                Label("iPhone 需要 ESP32 模式", systemImage: "cpu").font(.headline)
                Text("iPhone 不允许第三方 App 读取通知，NotiBridge 通过一块 ESP32 模块以蓝牙配件的身份接收 iPhone 通知，再经 USB 转到电脑。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("启用 ESP32 模式") { esp.mode = .esp32 }.hbGlassButton(prominent: true)
            }
        } else if esp.link == nil {
            CardBox {
                Label("ESP32 模块还没准备好", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text(esp.linkError.isEmpty ? "请先用 USB 线连接 ESP32 模块，并完成固件刷写。" : esp.linkError)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let onOpenEsp32 { Button("去 ESP32 模块页面") { onOpenEsp32() } }
                    Button("重试") { esp.startLinkIfPossible() }
                }
            }
        } else if let p = newIphone, p.ancsReady {
            CardBox {
                Label("已添加：\(iphoneName(p))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Text("这台 iPhone 的通知会经 ESP32 同步到这台电脑。").foregroundStyle(.secondary)
            }
        } else if iphoneDeadline == nil {
            Button("开始配对 iPhone") { startIphonePairingIfReady() }.hbGlassButton(prominent: true)
        } else {
            StepText(n: 1, text: "在 iPhone 上打开「设置 › 蓝牙」，在“其他设备”里点“NotiBridge”，然后点“配对”。")
            StepText(n: 2, text: "弹出“共享系统通知”时选择“允许”（错过了可以点 NotiBridge 右边的 ⓘ 打开“共享系统通知”）。")
            if let p = newIphone {
                Label("已配对“\(iphoneName(p))”，等待 iPhone 允许共享通知…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
            if !esp.iphoneProblem.isEmpty {
                Text(esp.iphoneProblem).font(.callout).foregroundStyle(.orange)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = Int((iphoneDeadline ?? ctx.date).timeIntervalSince(ctx.date))
                if left > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("配对窗口剩余 \(left / 60):\(String(format: "%02d", left % 60))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("配对窗口已关闭").foregroundStyle(.secondary)
                        Button("重新开始") { startIphonePairingIfReady() }
                    }
                }
            }
        }
    }
}

private struct StepText: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 选项卡片（使用方式、设备类型）
struct KindOption: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String
    var enabled: Bool = true
    var selected: Bool? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                    .foregroundStyle(enabled ? color : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hbGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - ESP32 模块页

struct Esp32Page: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var esp: Esp32Manager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if esp.mode == .esp32 {
                    Esp32Panel(esp: esp, onAddIphone: { model.openAddDevice(.iphone) })
                    Button("关闭 ESP32 模式（只用纯软件）") { esp.mode = .software }
                        .buttonStyle(.link)
                } else {
                    CardBox {
                        Label("ESP32 模块", systemImage: "cpu").font(.title3.bold())
                        Text("一块几十元的 ESP32 开发板，插在电脑 USB 上，由 NotiBridge 一键刷写固件。启用后在纯软件的基础上增加：")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Label("iPhone 通知：iPhone 在蓝牙设置里和 ESP32 配对，不用装 App", systemImage: "apple.logo")
                        Label("通话：所有手机都能在电脑上接打电话（即将支持）", systemImage: "phone")
                        Text("推荐带 USB 串口芯片（CH340 / CP210x）的 ESP32-WROOM-32 开发板。安卓、鸿蒙手机的通知照常通过局域网同步。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("启用 ESP32 模式") { esp.mode = .esp32 }.hbGlassButton(prominent: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .hbPageBackground()
    }
}

// MARK: - 使用方式文案

extension UseMode {
    var label: String { self == .software ? "纯软件" : "ESP32 模式" }
    var summary: String {
        self == .software
            ? "同步安卓、鸿蒙手机的通知，验证码自动复制。不需要额外硬件。"
            : "在纯软件的基础上，增加 iPhone 通知（经 ESP32 模块），以及所有手机在电脑上接打电话（即将支持）。需要一块插在电脑 USB 上的 ESP32 模块。"
    }
}
