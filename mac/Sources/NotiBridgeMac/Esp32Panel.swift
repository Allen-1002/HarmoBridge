import SwiftUI

/// ESP32 模块的检测与刷写面板（引导页和设置共用）。
struct Esp32Panel: View {
    @ObservedObject var esp: Esp32Manager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(esp.scanned ? "重新检测" : "检测已连接的 ESP32") { esp.scan() }
                    .hbGlassButton()
                if !esp.message.isEmpty {
                    Text(esp.message).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !esp.ports.isEmpty {
                Picker("串口", selection: $esp.selected) {
                    ForEach(esp.ports) { p in Text(p.label).tag(p.path) }
                }
                .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("检测固件") { esp.checkFirmware() }
                        .disabled(esp.firmware == .checking || esp.selected.isEmpty)
                    Button("刷写固件") { esp.flash() }
                        .disabled(esp.selected.isEmpty || esp.firmware == .checking)
                    if esp.firmware == .checking { ProgressView().controlSize(.small) }
                }
                switch esp.firmware {
                case let .found(version):
                    Label("已检测到 NotiBridge 固件 \(version)，可以使用通话功能", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case let .missing(reason):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("未检测到固件：\(reason)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        HStack {
                            Button("重新刷写固件") { esp.flash() }
                            Button("不刷写，稍后再说") { esp.firmware = .unknown }
                        }
                    }
                default:
                    EmptyView()
                }
            }
            Text("已经刷写过固件的模块，直接点“检测固件”即可；检测不通过时可以重新刷写或补齐固件，也可以先跳过。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
