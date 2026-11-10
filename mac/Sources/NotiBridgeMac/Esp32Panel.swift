import NotiBridgeCore
import SwiftUI

/// ESP32 模块的检测、刷写与连接状态面板（引导页和设置共用）。
struct Esp32Panel: View {
    @ObservedObject var esp: Esp32Manager

    private var flashing: Bool {
        if case .flashing = esp.firmware { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(esp.scanned ? "重新检测" : "检测已连接的 ESP32") { esp.scan() }
                    .hbGlassButton()
                    .disabled(flashing)
                if !esp.message.isEmpty {
                    Text(esp.message).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !esp.ports.isEmpty {
                Picker("串口", selection: $esp.selected) {
                    ForEach(esp.ports) { p in Text(p.label).tag(p.path) }
                }
                .frame(maxWidth: 420)
                .disabled(flashing)
                HStack(spacing: 10) {
                    Button("检测固件") { esp.checkFirmware() }
                        .disabled(esp.firmware == .checking || esp.selected.isEmpty || flashing)
                    Button("刷写固件") { esp.flash() }
                        .disabled(esp.selected.isEmpty || esp.firmware == .checking || flashing
                            || !Esp32Manager.firmwareAvailable)
                    if esp.firmware == .checking { ProgressView().controlSize(.small) }
                }
            }
            firmwareStatus
            if case .found = esp.firmware, esp.mode == .esp32 {
                iphoneStatus
            }
            Text("第一次使用先点“刷写固件”（约 30 秒）。已经刷写过的模块直接点“检测固件”。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var firmwareStatus: some View {
        switch esp.firmware {
        case let .found(version):
            Label("已检测到 NotiBridge 固件 \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if esp.needsFirmwareUpdate {
                HStack {
                    Text("NotiBridge 附带了新固件 \(Esp32Manager.bundledVersion)").font(.callout)
                    Button("更新固件") { esp.flash() }
                }
            }
        case let .missing(reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("未检测到固件：\(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button("刷写固件") { esp.flash() }.disabled(!Esp32Manager.firmwareAvailable)
                    Button("不刷写，稍后再说") { esp.firmware = .unknown }
                }
            }
        case let .flashing(text, progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress).frame(maxWidth: 420)
                Text("\(text)（不要拔掉板子）").font(.callout).foregroundStyle(.secondary)
            }
        case let .flashFailed(reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("刷写失败：\(reason)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("重试") { esp.flash() }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var iphoneStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = esp.link {
                Label(s.label, systemImage: s.ble == "ready" ? "iphone.radiowaves.left.and.right" : "iphone")
                    .foregroundStyle(s.ble == "ready" ? .green : .secondary)
                if s.bonds == 0 || s.pairing {
                    Text("在 iPhone 上打开「设置 › 蓝牙」，点 NotiBridge 并允许配对，然后在弹窗里允许“显示通知”。配对窗口约 3 分钟。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("配对新的 iPhone") { esp.pairNewIphone() }
                    if s.bonds > 0 { Button("删除 iPhone 配对") { esp.forgetIphones() } }
                }
            } else if !esp.linkError.isEmpty {
                Text(esp.linkError).font(.caption).foregroundStyle(.orange)
            } else {
                Text("正在连接 ESP32…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
