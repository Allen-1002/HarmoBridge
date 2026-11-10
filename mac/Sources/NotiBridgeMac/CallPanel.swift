import AppKit
import Combine
import NotiBridgeCore
import SwiftUI

/// 当前通话在界面上的状态（来电小窗、主窗口横条、菜单栏横条共用）。
@MainActor
final class CallSession: ObservableObject {
    @Published private(set) var call: PhoneCall = .idle
    /// 接通的时刻（用来算通话时长）
    @Published private(set) var startedAt: Date?
    @Published var muted = false {
        didSet { esp.setMuted(muted) }
    }
    /// 来电/通话对象在电脑通讯录里的名字（没有为 nil）
    @Published private(set) var contactName: String?
    /// 小窗收成胶囊
    @Published var compact = false

    let esp: Esp32Manager
    let contacts: ContactsDirectory
    private var cancellables = Set<AnyCancellable>()

    init(esp: Esp32Manager, contacts: ContactsDirectory) {
        self.esp = esp
        self.contacts = contacts
        esp.$call.receive(on: RunLoop.main).sink { [weak self] c in self?.update(c) }.store(in: &cancellables)
    }

    var isIdle: Bool { call.isIdle }
    var audioOnPC: Bool { esp.hfp?.audioToPC == true }

    var title: String {
        if let contactName { return contactName }
        return call.number.isEmpty ? "未知号码" : call.number
    }

    /// 名字下面那一行：号码（有名字时）+ 状态
    var subtitle: String {
        let state: String = switch call.state {
        case "incoming": "来电"
        case "dialing": "正在呼叫…"
        case "alerting": "对方振铃中…"
        case "active": call.held > 0 ? "通话保持中" : "通话中"
        default: ""
        }
        if contactName != nil && !call.number.isEmpty { return "\(call.number) · \(state)" }
        return state
    }

    private func update(_ c: PhoneCall) {
        let wasIdle = call.isIdle
        call = c
        if c.state == "active" {
            if startedAt == nil { startedAt = Date() }
        } else if c.isIdle {
            startedAt = nil
            muted = false
            compact = false
        }
        if wasIdle && !c.isIdle { compact = false }
        contactName = c.number.isEmpty ? nil : contacts.name(forNumber: c.number)
    }

    func answer() { esp.answer() }
    func hangUp() { esp.hangUp() }
    func toggleAudio() { esp.setAudioToPC(!audioOnPC) }
    func dtmf(_ c: Character) { esp.sendDtmf(c) }
}

/// 通话时长 mm:ss
struct CallDuration: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(0, Int(ctx.date.timeIntervalSince(since)))
                Text(String(format: "%02d:%02d", s / 60, s % 60)).monospacedDigit()
            }
        }
    }
}

/// 拨号键盘（通话中按 1 转人工这类）
struct DtmfPad: View {
    let send: (Character) -> Void
    private let keys: [[Character]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { k in
                        Button(String(k)) { send(k) }
                            .font(.title3.monospacedDigit())
                            .frame(width: 44, height: 32)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

/// 来电/通话控制：横条（主窗口、菜单栏）和小窗共用
struct CallControlsRow: View {
    @ObservedObject var session: CallSession
    @Binding var showPad: Bool

    var body: some View {
        HStack(spacing: 8) {
            if session.call.state == "incoming" {
                Button { session.answer() } label: { Label("接听", systemImage: "phone.fill") }
                    .tint(.green).buttonStyle(.borderedProminent)
                Button(role: .destructive) { session.hangUp() } label: { Label("拒接", systemImage: "phone.down.fill") }
                    .tint(.red).buttonStyle(.borderedProminent)
            } else {
                Button { session.muted.toggle() } label: {
                    Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                }
                .help(session.muted ? "取消静音" : "静音")
                .disabled(!session.audioOnPC)
                Button { session.toggleAudio() } label: {
                    Image(systemName: session.audioOnPC ? "iphone" : "speaker.wave.2.fill")
                }
                .help(session.audioOnPC ? "声音切回手机" : "声音切到电脑")
                Button { showPad.toggle() } label: { Image(systemName: "circle.grid.3x3.fill") }
                    .help("拨号键盘")
                Button(role: .destructive) { session.hangUp() } label: { Label("挂断", systemImage: "phone.down.fill") }
                    .tint(.red).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 主窗口和菜单栏顶部的通话横条
struct CallBanner: View {
    @ObservedObject var session: CallSession
    @State private var showPad = false

    var body: some View {
        if !session.isIdle {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: session.call.state == "incoming" ? "phone.arrow.down.left.fill" : "phone.fill")
                        .font(.title2).foregroundStyle(.green)
                        .symbolEffect(.pulse, isActive: session.call.state == "incoming")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.headline).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(session.subtitle)
                            CallDuration(since: session.startedAt)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    CallControlsRow(session: session, showPad: $showPad)
                }
                if showPad && !session.isIdle && session.call.state != "incoming" {
                    DtmfPad { session.dtmf($0) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.green.opacity(0.45)))
        }
    }
}

/// 来电/通话小窗的内容
struct CallPanelView: View {
    @ObservedObject var session: CallSession
    @State private var showPad = false
    var onResize: () -> Void = {}

    var body: some View {
        Group {
            if session.compact {
                // 胶囊：名字 + 时长，点一下展开
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill").foregroundStyle(.green)
                    Text(session.title).lineLimit(1)
                    CallDuration(since: session.startedAt).foregroundStyle(.secondary)
                    Button { session.hangUp() } label: { Image(systemName: "phone.down.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.red).help("挂断")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { session.compact = false }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(.title3.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(session.subtitle)
                                CallDuration(since: session.startedAt)
                            }
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.call.state != "incoming" {
                            Button { session.compact = true } label: { Image(systemName: "chevron.up.circle") }
                                .buttonStyle(.borderless).help("收起")
                        }
                    }
                    CallControlsRow(session: session, showPad: $showPad)
                    if showPad && session.call.state != "incoming" {
                        DtmfPad { session.dtmf($0) }
                    }
                }
                .padding(16)
                .frame(width: 300, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: session.compact ? 20 : 16, style: .continuous))
        .onChange(of: session.compact) { onResize() }
        .onChange(of: showPad) { onResize() }
    }
}

/// 来电/通话小窗：屏幕右上角、浮在所有窗口最上面、不抢焦点，电话结束才消失。可以拖动，也可以收成胶囊。
@MainActor
final class CallPanelController {
    private var panel: NSPanel?
    private let session: CallSession
    private var cancellables = Set<AnyCancellable>()

    init(session: CallSession) {
        self.session = session
        session.$call.receive(on: RunLoop.main).sink { [weak self] c in
            if c.isIdle { self?.hide() } else { self?.show() }
        }.store(in: &cancellables)
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            let host = NSHostingView(rootView: CallPanelView(session: session, onResize: { [weak self] in
                DispatchQueue.main.async { self?.fit() }
            }))
            p.contentView = host
            panel = p
            place()
        }
        fit()
        panel?.orderFrontRegardless()
    }

    /// 首次出现放在屏幕右上角（菜单栏下面）
    private func place() {
        guard let p = panel, let screen = NSScreen.main else { return }
        fit()
        let f = screen.visibleFrame
        p.setFrameTopLeftPoint(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - 12))
    }

    /// 内容大小变化（收起/展开、拨号键盘）时调整窗口，保持右上角不动
    private func fit() {
        guard let p = panel, let v = p.contentView else { return }
        let size = v.fittingSize
        let topRight = NSPoint(x: p.frame.maxX, y: p.frame.maxY)
        p.setFrame(NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height),
                   display: true)
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
