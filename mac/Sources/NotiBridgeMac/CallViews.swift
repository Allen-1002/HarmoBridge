import NotiBridgeCore
import SwiftUI

/// ESP32 页“通话”一行：免提连接、配对手机、当前通话（接听/挂断）、拨号。
struct CallRow: View {
    @ObservedObject var esp: Esp32Manager
    @State private var number = ""
    @State private var confirmForget: PairedPhone?

    private var firmwareSupportsCalls: Bool {
        if case let .found(v) = esp.firmware { return UpdateCore.compareVersions(v, "1.3.0").map { $0 >= 0 } ?? false }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !firmwareSupportsCalls {
                Text("需要固件 1.3.0 或更新：在上面的“固件”一行更新后即可使用通话。")
                    .foregroundStyle(.secondary)
            } else {
                linkLine
                if let code = esp.pairCode {
                    Text("手机上显示的配对码应为 \(code)，一致时在手机上点“配对”。").font(.callout)
                }
                if esp.hfp?.connected == true { callControls }
                phonesList
            }
        }
        .confirmationDialog("删除“\(confirmForget?.displayName ?? "")”的通话配对？", isPresented: Binding(
            get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let p = confirmForget { esp.forgetPhone(p.id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("也请在手机的蓝牙设置里忽略 NotiBridge。")
        }
    }

    @ViewBuilder private var linkLine: some View {
        if let h = esp.hfp {
            switch h.state {
            case "connected":
                Text("已连接 \(h.name.isEmpty ? "手机" : h.name)\(h.networkOperator.isEmpty ? "" : " · \(h.networkOperator)")")
            case "connecting":
                Text("正在连接手机…").foregroundStyle(.secondary)
            default:
                Text(esp.phones.isEmpty ? "还没有配对手机" : "手机未连接（ESP32 会自动重连）").foregroundStyle(.secondary)
            }
        } else {
            Text("等待 ESP32…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var callControls: some View {
        let c = esp.call
        if !c.isIdle {
            HStack(spacing: 10) {
                Label("\(c.label) \(c.number)", systemImage: c.state == "incoming" ? "phone.arrow.down.left" : "phone.fill")
                    .font(.headline)
                if c.state == "incoming" {
                    Button("接听") { esp.answer() }.keyboardShortcut(.defaultAction)
                    Button("拒接", role: .destructive) { esp.hangUp() }
                } else {
                    Button("挂断", role: .destructive) { esp.hangUp() }
                }
            }
            Text("通话声音目前在手机上，电脑端声音即将支持。").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                TextField("拨打号码", text: $number).frame(maxWidth: 200).onSubmit { esp.dial(number) }
                Button("拨打") { esp.dial(number) }.disabled(number.filter(\.isNumber).isEmpty)
                Button("重拨") { esp.redial() }
            }
        }
    }

    @ViewBuilder private var phonesList: some View {
        ForEach(esp.phones) { p in
            HStack {
                Image(systemName: p.connected ? "phone.connection" : "phone")
                Text(p.displayName)
                Text(p.connected ? "已连接" : "未连接").foregroundStyle(.secondary).font(.caption)
                Spacer()
                if !p.connected { Button("连接") { esp.connectPhone(p.id) } }
                Button("删除") { confirmForget = p }
            }
        }
        HStack {
            Button(esp.phones.isEmpty ? "配对手机" : "配对新手机") { esp.pairNewIphone() }
            Text("然后在手机「设置 › 蓝牙」里点 NotiBridge。安卓、鸿蒙、iPhone 都可以。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
