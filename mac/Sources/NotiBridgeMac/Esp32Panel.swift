import AppKit
import NotiBridgeCore
import SwiftUI

/// ESP32 模块状态卡：板子 → 固件 → iPhone → 通话，每一行只在需要处理时给出按钮。
/// ESP32 模块页和首次引导共用。
struct Esp32Panel: View {
    @ObservedObject var esp: Esp32Manager
    /// “添加 iPhone”（首次引导里为 nil：下一步就是添加设备）
    var onAddIphone: (() -> Void)?
    @State private var showAdvanced = false
    @State private var confirmForgetAll = false

    private var flashing: Bool {
        if case .flashing = esp.firmware { return true }
        return false
    }

    private var firmwareFound: Bool {
        if case .found = esp.firmware { return true }
        return false
    }

    private var selectedPort: Esp32Port? { esp.ports.first { $0.path == esp.selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardBox {
                StatusLine(title: "板子", ok: selectedPort != nil) { boardRow }
                Divider().opacity(0.5)
                StatusLine(title: "固件", ok: firmwareFound) { firmwareRow }
                Divider().opacity(0.5)
                StatusLine(title: "iPhone", ok: esp.iphones.contains(where: \.ancsReady)) { iphoneRow }
                Divider().opacity(0.5)
                StatusLine(title: "通话", ok: esp.hfp?.connected == true) { CallRow(esp: esp) }
            }
            DisclosureGroup("高级", isExpanded: $showAdvanced) { advanced.padding(.top, 8) }
        }
        .onAppear { if !esp.scanned { detect() } }
        // 插上、拔掉或换板子后自动刷新：每 2 秒看一次串口列表，有变化就重新检测
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !flashing { esp.refreshPortsIfChanged() }
            }
        }
        .confirmationDialog("删除 ESP32 上的全部 iPhone 配对？", isPresented: $confirmForgetAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { esp.forgetIphones() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有 iPhone 都需要重新配对。也请在每台 iPhone 的「设置 › 蓝牙」里忽略 NotiBridge。")
        }
    }

    /// 找串口；找到了而且还没连上固件，就检测固件
    private func detect() {
        esp.scan()
        if !esp.selected.isEmpty && esp.link == nil && esp.firmware != .checking { esp.checkFirmware() }
    }

    // MARK: 各行

    @ViewBuilder private var boardRow: some View {
        if let p = selectedPort {
            Text("已连接 · \(p.label)").foregroundStyle(.secondary)
            if esp.ports.count > 1 {
                Picker("串口", selection: $esp.selected) {
                    ForEach(esp.ports) { p in Text(p.label).tag(p.path) }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(flashing)
                .onChange(of: esp.selected) { esp.checkFirmware() }
            }
        } else {
            Text(esp.message.isEmpty ? "未检测到。用支持数据传输的 USB 线连接 ESP32，插上后会自动检测。" : esp.message)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var firmwareRow: some View {
        switch esp.firmware {
        case let .found(version):
            Text("固件 \(version)").foregroundStyle(.secondary)
            if esp.needsFirmwareUpdate {
                HStack {
                    Text("有新固件 \(esp.latestFirmwareVersion ?? "")").font(.callout)
                    Button("更新固件") { esp.flash() }
                }
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检测…").foregroundStyle(.secondary)
            }
        case let .missing(reason):
            Text("未检测到 NotiBridge 固件：\(reason)").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            flashButton(title: "刷写固件")
        case let .flashing(text, progress):
            ProgressView(value: progress).frame(maxWidth: 360)
            Text("\(text)（不要拔掉板子）").font(.callout).foregroundStyle(.secondary)
        case let .flashFailed(reason):
            Text("刷写失败：\(reason)").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            flashButton(title: "重试")
        case .unknown:
            if selectedPort != nil {
                HStack {
                    Button("检测固件") { esp.checkFirmware() }
                    flashButton(title: "刷写固件")
                }
            } else {
                Text("先连接板子").foregroundStyle(.secondary)
            }
        }
    }

    private func flashButton(title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(title) { esp.flash() }
                .hbGlassButton(prominent: true)
                .disabled(esp.selected.isEmpty || !Esp32Manager.firmwareAvailable)
            Text("第一次刷写某块板子前会先自动备份板子上原有的固件（约 1~3 分钟），之后可以在“高级”里一键还原。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var iphoneRow: some View {
        if esp.link == nil {
            Text(esp.linkError.isEmpty ? (firmwareFound ? "正在连接 ESP32…" : "固件就绪后可以添加 iPhone") : esp.linkError)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            if esp.iphones.isEmpty {
                Text("还没有配对 iPhone").foregroundStyle(.secondary)
            } else {
                ForEach(esp.iphones, id: \.id) { p in
                    Label("\(iphoneName(p)) · \(iphoneStatus(p))",
                          systemImage: p.ancsReady ? "checkmark.circle.fill" : "iphone")
                        .foregroundStyle(p.ancsReady ? .green : .secondary)
                }
            }
            if !esp.iphoneProblem.isEmpty && !esp.iphones.contains(where: \.ancsReady) {
                Text(esp.iphoneProblem).font(.caption).foregroundStyle(.orange)
            }
            if let onAddIphone {
                Button("添加 iPhone") { onAddIphone() }
            }
        }
    }

    // MARK: 高级

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("重新检测") { detect() }.disabled(flashing)
                Button("重新刷写固件") { esp.flash() }
                    .disabled(esp.selected.isEmpty || flashing || esp.firmware == .checking
                        || !Esp32Manager.firmwareAvailable)
                if esp.link != nil && !esp.iphones.isEmpty {
                    Button("删除全部 iPhone 配对", role: .destructive) { confirmForgetAll = true }
                }
            }
            HStack(spacing: 10) {
                Button("还原原固件") { confirmRestore() }
                    .disabled(esp.backups.isEmpty || esp.selected.isEmpty || flashing || esp.firmware == .checking)
                Button("打开备份文件夹") { esp.revealBackups() }
                Text(esp.backups.isEmpty ? "还没有备份（第一次刷写时自动备份）" : "已备份 \(esp.backups.count) 块板子的原固件")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "还原原固件？"
        alert.informativeText = "会把这块板子恢复成第一次刷写 NotiBridge 之前的样子，iPhone 配对也会一起清除。备份文件会保留，之后还可以再刷写 NotiBridge。"
        alert.addButton(withTitle: "还原")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { esp.restoreOriginal() }
    }
}

/// 状态卡中的一行：左边标题和对勾，右边内容
private struct StatusLine<Content: View>: View {
    let title: String
    let ok: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(title).font(.headline).frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) { content }
            Spacer(minLength: 0)
        }
    }
}
