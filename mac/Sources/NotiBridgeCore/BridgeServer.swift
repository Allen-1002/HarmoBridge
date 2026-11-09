import Foundation
import Network

/// 局域网 WebSocket 服务端（Network.framework），可选用 Bonjour 广播 _notibridge._tcp。
/// 所有回调都在主队列上执行。防滥用策略见 ConnectionGuard（docs/protocol.md “电脑端连接限制”）。
public final class BridgeServer {
    public enum Event {
        case listening(port: UInt16)
        case stopped(String)
        case output(SessionMachine.Output, connection: ObjectIdentifier)
        case disconnected(connection: ObjectIdentifier, deviceId: String?, wasAuthenticated: Bool)
        /// 新连接被限制策略拒绝（连接数、速率或封禁）
        case rejected(ip: String, reason: String)
    }

    public static let serviceType = "_notibridge._tcp"

    private struct Session {
        let conn: NWConnection
        let machine: SessionMachine
        let ip: String
    }

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private let makeMachine: () -> SessionMachine
    public let guardian: ConnectionGuard
    /// 测试用：只监听 127.0.0.1，不广播 Bonjour
    private let loopbackOnly: Bool
    public var onEvent: ((Event) -> Void)?

    public init(limits: ConnectionGuard.Limits = .init(), loopbackOnly: Bool = false,
                makeMachine: @escaping () -> SessionMachine) {
        self.makeMachine = makeMachine
        self.loopbackOnly = loopbackOnly
        guardian = ConnectionGuard(limits: limits)
    }

    public func start(port: UInt16, serviceName: String, macId: String = "") {
        stop()
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = guardian.limits.maxFrameAfterAuth
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        if loopbackOnly {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        do {
            let l: NWListener
            if loopbackOnly {
                l = try NWListener(using: params)
            } else {
                guard let p = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
                l = try NWListener(using: params, on: p)
                // TXT 记录带上电脑 ID 和平台：手机据此识别已配对的电脑并在 IP 变化时自动更新地址
                var txt = NWTXTRecord()
                txt["id"] = macId
                txt["platform"] = "mac"
                l.service = NWListener.Service(name: serviceName, type: Self.serviceType, domain: nil, txtRecord: txt)
            }
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

    public var port: UInt16? { listener?.port?.rawValue }

    public func stop() {
        listener?.cancel()
        listener = nil
        for (_, s) in sessions { s.conn.cancel() }
    }

    public var connectionCount: Int { sessions.count }

    public func send(_ text: String, to id: ObjectIdentifier) {
        guard let s = sessions[id] else { return }
        sendRaw(text, on: s.conn)
    }

    /// seq 为 nil 表示电脑主动推送
    public func sendSettings(_ st: SharedSettings, seq: Int?, to id: ObjectIdentifier) {
        guard let s = sessions[id], let frame = s.machine.settingsFrame(st, seq: seq) else { return }
        sendRaw(frame, on: s.conn)
    }

    /// 已认证（在线）的连接
    public var authenticatedConnections: [ObjectIdentifier] {
        sessions.filter { $0.value.machine.isAuthenticated }.map(\.key)
    }

    /// 电脑上改了开关：推送给所有在线手机
    public func broadcastSettings(_ st: SharedSettings, except: ObjectIdentifier? = nil) {
        for id in authenticatedConnections where id != except {
            sendSettings(st, seq: nil, to: id)
        }
    }

    /// 只断开某台手机（取消配对时）
    public func disconnect(deviceId: String) {
        for (_, s) in sessions where s.machine.deviceId == deviceId { s.conn.cancel() }
    }

    /// 电脑上取消配对：手机在线时先发 unpair（手机随即删除这台电脑），稍后断开。返回是否已通知到在线手机。
    @discardableResult
    public func unpair(deviceId: String) -> Bool {
        var notified = false
        for (_, s) in sessions where s.machine.deviceId == deviceId {
            if let frame = s.machine.unpairFrame() {
                sendRaw(frame, on: s.conn)
                notified = true
                let conn = s.conn
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { conn.cancel() }
            } else {
                s.conn.cancel()
            }
        }
        return notified
    }

    public func ack(seq: Int, result: String, to id: ObjectIdentifier) {
        guard let s = sessions[id], let frame = s.machine.ack(seq: seq, result: result) else { return }
        sendRaw(frame, on: s.conn)
    }

    public func disconnectAll() {
        for (_, s) in sessions { s.conn.cancel() }
    }

    static func ipString(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        var s: String
        switch host {
        case let .ipv4(a): s = "\(a)"
        case let .ipv6(a): s = "\(a)"
        case let .name(n, _): s = n
        @unknown default: s = "\(host)"
        }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        // IPv4 映射的 IPv6 地址按 IPv4 计
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }

    private func accept(_ conn: NWConnection) {
        let ip = Self.ipString(conn.endpoint)
        switch guardian.admit(ip: ip) {
        case .allow:
            break
        case .tooManyConnections:
            conn.cancel()
            onEvent?(.rejected(ip: ip, reason: "连接数已达上限"))
            return
        case .rateLimited:
            conn.cancel()
            onEvent?(.rejected(ip: ip, reason: "新连接过于频繁"))
            return
        case .lockedOut:
            conn.cancel()
            onEvent?(.rejected(ip: ip, reason: "多次认证失败，暂时封禁"))
            return
        }
        let id = ObjectIdentifier(conn)
        sessions[id] = Session(conn: conn, machine: makeMachine(), ip: ip)
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
        // 握手/认证超时：10 秒内必须完成认证；配对中放宽，给用户核对校验码
        let short = guardian.deadline(isPairing: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + short) { [weak self] in
            guard let self, let s = self.sessions[id], !s.machine.isAuthenticated else { return }
            if !s.machine.isPairing {
                s.conn.cancel()
                return
            }
            let rest = self.guardian.deadline(isPairing: true) - short
            DispatchQueue.main.asyncAfter(deadline: .now() + rest) { [weak self] in
                guard let self, let s = self.sessions[id], !s.machine.isAuthenticated else { return }
                s.conn.cancel()
            }
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
            guard let s = self.sessions[id] else { return }
            if let data, data.count > self.guardian.maxFrame(authenticated: s.machine.isAuthenticated) {
                // 认证前不接受大帧
                self.guardian.recordFailure(ip: s.ip)
                self.onEvent?(.output(.log("帧过大（\(data.count) 字节），已断开"), connection: id))
                conn.cancel()
                return
            }
            if let data, let meta, meta.opcode == .text, let text = String(data: data, encoding: .utf8) {
                for out in s.machine.handle(text) {
                    switch out {
                    case let .send(frame):
                        self.sendRaw(frame, on: conn)
                    case let .close(reason):
                        if SessionMachine.failureReasons.contains(reason) { self.guardian.recordFailure(ip: s.ip) }
                        // 让最后一帧先发出去再断开
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
                    case .authenticated:
                        self.guardian.recordSuccess(ip: s.ip)
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
        guardian.connectionClosed()
        s.conn.stateUpdateHandler = nil
        onEvent?(.disconnected(connection: id, deviceId: s.machine.deviceId, wasAuthenticated: s.machine.isAuthenticated))
    }
}
