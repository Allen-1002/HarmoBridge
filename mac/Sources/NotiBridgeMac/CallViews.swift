import NotiBridgeCore
import SwiftUI

/// ESP32 页“通话”一行：免提连接、配对手机、当前通话（接听/挂断）、拨号。
struct CallRow: View {
    @ObservedObject var esp: Esp32Manager
    @EnvironmentObject var model: AppModel
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
            if c.state == "active" || c.state == "dialing" || c.state == "alerting" {
                let onPC = esp.hfp?.audioToPC == true
                HStack {
                    Label(onPC ? "声音在这台电脑上" : "声音在手机上", systemImage: onPC ? "speaker.wave.2" : "iphone")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(onPC ? "切回手机" : "切到电脑") { esp.setAudioToPC(!onPC) }
                }
            }
        } else {
            DialBox(number: $number, contacts: model.contacts, recent: model.recentCalls) { esp.dial($0) }
            Button("重拨") { esp.redial() }.font(.caption)
        }
    }

    @ViewBuilder private var phonesList: some View {
        ForEach(esp.phones) { p in
            HStack {
                Image(systemName: p.connected ? "phone.connection" : "phone")
                Text(p.displayName)
                Text(p.connected ? "已连接" : "未连接").foregroundStyle(.secondary).font(.caption)
                if p.preferred { Text("优先").font(.caption).foregroundStyle(.tint) }
                Spacer()
                if !p.connected { Button(esp.hfp?.connected == true ? "切换到这台" : "连接") { esp.switchPhone(p.id) } }
                if esp.phones.count > 1 {
                    Button(p.preferred ? "取消优先" : "设为优先") { esp.preferPhone(p.preferred ? nil : p.id) }
                }
                Button("删除") { confirmForget = p }
            }
        }
        HStack {
            Button(esp.phones.isEmpty ? "配对手机" : "配对新手机") { esp.pairNewIphone() }
            Text("然后在手机「设置 › 蓝牙」里点“NotiBridge 通话”。安卓、鸿蒙、iPhone 都可以；同一时间只能有一台手机连着通话。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 拨号框：输入名字或号码，下面列出匹配的联系人；空着时列出最近通话
struct DialBox: View {
    @Binding var number: String
    @ObservedObject var contacts: ContactsDirectory
    let recent: [String]
    let dial: (String) -> Void
    @State private var showList = false

    private var suggestions: [ContactEntry] {
        let q = number.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return recent.prefix(5).map { ContactEntry(name: contacts.name(forNumber: $0) ?? "", number: $0) }
        }
        return contacts.search(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("输入名字或号码", text: $number)
                    .frame(maxWidth: 220)
                    .onSubmit { submit() }
                Button("拨打") { submit() }.disabled(target == nil)
                Button { showList = true } label: { Label("联系人", systemImage: "person.crop.circle") }
                    .disabled(!contacts.authorized)
                    .popover(isPresented: $showList, arrowEdge: .bottom) {
                        ContactPicker(contacts: contacts) { e in
                            showList = false
                            number = e.number
                            dial(e.number)
                        }
                    }
            }
            ForEach(suggestions) { e in
                Button {
                    number = e.number
                    dial(e.number)
                } label: {
                    HStack {
                        Image(systemName: "phone")
                        Text(e.name.isEmpty ? e.number : e.name)
                        if !e.name.isEmpty { Text(e.number).foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
                .buttonStyle(.borderless)
            }
            if !contacts.authorized {
                Text(contacts.status == .denied ? "没有通讯录权限：在「系统设置 › 隐私与安全性 › 通讯录」里允许 NotiBridge 后，来电和拨号可以显示联系人名字。"
                                                : "允许访问通讯录后，来电和拨号可以显示联系人名字。")
                    .font(.caption).foregroundStyle(.secondary)
                if contacts.status == .notDetermined { Button("允许访问通讯录") { contacts.requestAccess() }.font(.caption) }
            }
        }
    }

    /// 输入的是号码就拨号码；是名字且只匹配到一个联系人就拨他
    private var target: String? {
        let digits = number.filter { "0123456789+*#".contains($0) }
        if !digits.isEmpty && digits.count == number.filter({ !$0.isWhitespace && $0 != "-" }).count { return digits }
        let m = contacts.search(number)
        return m.count == 1 ? m[0].number : nil
    }

    private func submit() { if let t = target { dial(t) } }
}

/// 完整的联系人列表：按名字排序，顶部可以筛选，点一下拨号
struct ContactPicker: View {
    @ObservedObject var contacts: ContactsDirectory
    let pick: (ContactEntry) -> Void
    @State private var filter = ""

    private var list: [ContactEntry] {
        let all = contacts.index.entries.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : contacts.index.search(q, limit: 500)
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("筛选", text: $filter).textFieldStyle(.roundedBorder)
            if list.isEmpty {
                Text("没有联系人").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                List(list) { e in
                    Button { pick(e) } label: {
                        HStack {
                            Text(e.name)
                            Spacer()
                            Text(e.number).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 320, height: 420)
    }
}
