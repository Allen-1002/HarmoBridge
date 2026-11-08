import Foundation
import HarmoBridgeCore
import Network

/// 局域网 WebSocket 服务端（Network.framework），同时用 Bonjour 广播 _harmobridge._tcp。
/// 所有回调都在主队列上执行。
final class BridgeServer {
    enum Event {
        case listening(port: UInt16)
        case stopped(String)
        case output(SessionMachine.Output, connection: ObjectIdentifier)
        case disconnected(connection: ObjectIdentifier, deviceId: String?, wasAuthenticated: Bool)
    }

    static let serviceType = "_harmobridge._tcp"
    private let authTimeout: TimeInterval = 60 // 配对时要留出用户核对校验码的时间

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: (conn: NWConnection, machine: SessionMachine)] = [:]
    private let makeMachine: () -> SessionMachine
    var onEvent: ((Event) -> Void)?

    init(makeMachine: @escaping () -> SessionMachine) {
        self.makeMachine = makeMachine
    }

    func start(port: UInt16, serviceName: String, macId: String = "") {
        stop()
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 256 * 1024
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        do {
            guard let p = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
            let l = try NWListener(using: params, on: p)
            // TXT 记录带上电脑 ID 和平台：手机据此识别已配对的电脑并在 IP 变化时自动更新地址
            var txt = NWTXTRecord()
            txt["id"] = macId
            txt["platform"] = "mac"
            l.service = NWListener.Service(name: serviceName, type: Self.serviceType, domain: nil, txtRecord: txt)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onEvent?(.listening(port: l.port?.rawValue ?? port))
                case let .failed(err):
                    self?.onEvent?(.stopped("监听失败：\(err)"))
                case .cancelled:
                    self?.onEvent?(.stopped("已停止"))
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: .main)
            listener = l
        } catch {
            onEvent?(.stopped("无法监听端口 \(port)：\(error)"))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, s) in sessions { s.conn.cancel() }
        sessions.removeAll()
    }

    func send(_ text: String, to id: ObjectIdentifier) {
        guard let s = sessions[id] else { return }
        sendRaw(text, on: s.conn)
    }

    /// seq 为 nil 表示 Mac 主动推送
    func sendSettings(_ st: SharedSettings, seq: Int?, to id: ObjectIdentifier) {
        guard let s = sessions[id], let frame = s.machine.settingsFrame(st, seq: seq) else { return }
        sendRaw(frame, on: s.conn)
    }

    /// 已认证（在线）的连接
    var authenticatedConnections: [ObjectIdentifier] {
        sessions.filter { $0.value.machine.isAuthenticated }.map(\.key)
    }

    /// Mac 上改了开关：推送给所有在线手机
    func broadcastSettings(_ st: SharedSettings, except: ObjectIdentifier? = nil) {
        for id in authenticatedConnections where id != except {
            sendSettings(st, seq: nil, to: id)
        }
    }

    /// 只断开某台手机（取消配对时）
    func disconnect(deviceId: String) {
        for (_, s) in sessions where s.machine.deviceId == deviceId { s.conn.cancel() }
    }

    func ack(seq: Int, result: String, to id: ObjectIdentifier) {
        guard let s = sessions[id], let frame = s.machine.ack(seq: seq, result: result) else { return }
        sendRaw(frame, on: s.conn)
    }

    func disconnectAll() {
        for (_, s) in sessions { s.conn.cancel() }
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        sessions[id] = (conn, makeMachine())
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(id)
            default:
                break
            }
        }
        conn.start(queue: .main)
        receive(on: conn, id: id)
        // 未在限定时间内完成认证/配对则断开，防止空连接占用
        DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout) { [weak self] in
            guard let self, let s = self.sessions[id], !s.machine.isAuthenticated else { return }
            s.conn.cancel()
        }
    }

    private func receive(on conn: NWConnection, id: ObjectIdentifier) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                conn.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let meta, meta.opcode == .close {
                conn.cancel()
                return
            }
            if let data, let meta, meta.opcode == .text, let text = String(data: data, encoding: .utf8),
               let s = self.sessions[id] {
                for out in s.machine.handle(text) {
                    switch out {
                    case let .send(frame):
                        self.sendRaw(frame, on: conn)
                    case .close:
                        // 让最后一帧先发出去再断开
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
                    default:
                        break
                    }
                    self.onEvent?(.output(out, connection: id))
                }
            }
            if self.sessions[id] != nil {
                self.receive(on: conn, id: id)
            }
        }
    }

    private func sendRaw(_ text: String, on conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        onEvent?(.disconnected(connection: id, deviceId: s.machine.deviceId, wasAuthenticated: s.machine.isAuthenticated))
    }
}
