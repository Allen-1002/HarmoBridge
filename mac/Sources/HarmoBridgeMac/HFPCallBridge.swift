import Foundation
import IOBluetooth

/// 实验：让 Mac 作为蓝牙 HFP 免提设备（Hands-Free），连接已配对的手机（Audio Gateway）。
/// 基于 IOBluetooth 的 IOBluetoothHandsFreeDevice。能否与具体手机/系统版本配合需实测。
final class HFPCallBridge: NSObject, CallBridge, IOBluetoothHandsFreeDeviceDelegate {
    private(set) var state: CallState = .unavailable("未连接") {
        didSet {
            if oldValue != state { onStateChange?(state) }
        }
    }
    var onStateChange: ((CallState) -> Void)?
    var onLog: ((String) -> Void)?

    private let device: IOBluetoothDevice
    private var hf: IOBluetoothHandsFreeDevice?
    private var number = ""
    private var callActive = false
    private var setupMode = 0

    init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private var timeoutWork: DispatchWorkItem?

    /// 先做 SDP 查询拿到手机 HFP 网关（0x111F）的 RFCOMM 通道，再建立 HFP 连接。
    /// 不查询时 IOBluetooth 会默认用通道 1，手机上通常不是 HFP 通道，导致一直卡在“连接中”。
    func connect() {
        state = .connecting
        log("查询 \(device.name ?? "手机") 的蓝牙服务（SDP）…")
        let r = device.performSDPQuery(self)
        if r != kIOReturnSuccess {
            log("SDP 查询发起失败：\(r)，直接尝试连接")
            startHFP()
        }
        armTimeout()
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        log("SDP 查询完成：\(status)")
        let uuid = IOBluetoothSDPUUID(uuid16: 0x111F) // Handsfree Audio Gateway
        if let rec = device.getServiceRecord(for: uuid) {
            var channel: BluetoothRFCOMMChannelID = 0
            if rec.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
                log("手机 HFP 网关服务存在，RFCOMM 通道 \(channel)")
            } else {
                log("手机 HFP 网关服务存在，但读不到 RFCOMM 通道")
            }
        } else {
            log("手机没有公布 HFP 网关服务（0x111F），无法作为免提连接")
        }
        startHFP()
    }

    private func startHFP() {
        if hf == nil {
            hf = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        }
        guard let hf else {
            state = .unavailable("无法创建免提设备")
            return
        }
        log("正在以 HFP 免提身份连接 \(device.name ?? "手机")")
        hf.connect()
    }

    private func armTimeout() {
        timeoutWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.state = .unavailable("连接超时：系统没有建立 HFP 通道")
            self.log("20 秒内未建立 HFP 连接。可能原因：手机拒绝了 Mac 的免提连接，或新版 macOS 的 IOBluetooth 不再支持免提角色")
        }
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    }

    func disconnect() {
        hf?.disconnect()
        state = .unavailable("已断开")
    }

    func answer() {
        log("接听")
        hf?.acceptCall()
    }

    func hangUp() {
        log("挂断/拒接")
        hf?.endCall()
    }

    func dial(_ number: String) {
        let n = number.filter { "0123456789+*#".contains($0) }
        guard !n.isEmpty else { return }
        self.number = n
        log("拨号 \(Self.mask(n))")
        hf?.dialNumber(n)
    }

    func audioToComputer() {
        log("请求把通话音频切到 Mac")
        hf?.transferAudioToComputer()
    }

    func audioToPhone() {
        log("请求把通话音频切回手机")
        hf?.transferAudioToPhone()
    }

    // MARK: - IOBluetoothHandsFreeDelegate

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        let ok = status?.intValue == 0
        log("HFP 连接结果：\(status?.intValue ?? -1)\(ok ? "（成功）" : "（失败，见下方说明）")")
        state = ok ? .idle : .unavailable("HFP 连接失败（\(status?.intValue ?? -1)）")
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        log("HFP 已断开：\(status?.intValue ?? -1)")
        state = .unavailable("HFP 已断开")
        callActive = false
        setupMode = 0
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        log("通话音频（SCO）已建立：\(status?.intValue ?? -1)")
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        log("通话音频（SCO）已关闭：\(status?.intValue ?? -1)")
    }

    // MARK: - IOBluetoothHandsFreeDeviceDelegate

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable: NSNumber!) {
        log("手机网络服务：\(isServiceAvailable?.intValue == 1 ? "可用" : "不可用")")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive: NSNumber!) {
        callActive = isCallActive?.intValue == 1
        recompute()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode: NSNumber!) {
        setupMode = callSetupMode?.intValue ?? 0
        recompute()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        self.number = number ?? ""
        log("来电号码 \(Self.mask(self.number))")
        recompute()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt: NSNumber!) {
        if case .incoming = state { return }
        setupMode = 1
        recompute()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength: NSNumber!) {}
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge: NSNumber!) {}

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode resultCode: String!) {
        log("未处理的 AT 结果：\(resultCode ?? "")")
    }

    // MARK: -

    /// HFP 指示：call=0/1；callsetup=0 无、1 来电、2 呼出拨号中、3 对方振铃
    private func recompute() {
        let shown = number.isEmpty ? "未知号码" : number
        if callActive {
            state = .active(number: shown)
        } else if setupMode == 1 {
            state = .incoming(number: shown)
        } else if setupMode == 2 || setupMode == 3 {
            state = .dialing(number: shown)
        } else {
            state = .idle
            number = ""
        }
    }

    private func log(_ s: String) {
        DispatchQueue.main.async { self.onLog?(s) }
    }

    /// 日志中号码只保留后 4 位
    static func mask(_ n: String) -> String {
        n.count <= 4 ? n : String(repeating: "*", count: n.count - 4) + n.suffix(4)
    }
}
