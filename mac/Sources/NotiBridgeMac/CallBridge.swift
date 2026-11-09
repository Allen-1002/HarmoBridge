import Foundation

/// 通话模块接口，与通知模块解耦。
/// 当前实现：HFPCallBridge（Mac 自身作为蓝牙免提设备，实验）。
/// 预留实现：ESP32（经典蓝牙 HFP + USB 串口），协议中 kind 以 "call." 开头的消息保留给它。
protocol CallBridge: AnyObject {
    var state: CallState { get }
    var onStateChange: ((CallState) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    func connect()
    func disconnect()
    func answer()
    func hangUp()
    func dial(_ number: String)
    func audioToComputer()
    func audioToPhone()
}

enum CallState: Equatable {
    case unavailable(String)
    case connecting
    case idle
    case incoming(number: String)
    case dialing(number: String)
    case active(number: String)

    var label: String {
        switch self {
        case let .unavailable(reason): return "不可用：\(reason)"
        case .connecting: return "连接中"
        case .idle: return "空闲"
        case let .incoming(n): return "来电 \(n)"
        case let .dialing(n): return "呼出 \(n)"
        case let .active(n): return "通话中 \(n)"
        }
    }
}
