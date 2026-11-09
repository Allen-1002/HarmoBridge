using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;

namespace NotiBridge.Core;

/// <summary>
/// 局域网 WebSocket 服务端（TcpListener + 手写 HTTP 升级握手，不需要管理员权限注册 URL）。
/// 每条连接一个 SessionMachine；同一时刻可以有多台手机在线。
/// 事件在线程池线程上触发，界面层自行切回 UI 线程。
/// </summary>
public sealed class BridgeServer : IDisposable
{
    public abstract record Event
    {
        public sealed record Listening(int Port) : Event;
        public sealed record Stopped(string Reason) : Event;
        public sealed record Output(SessionOutput Value, Guid Connection) : Event;
        public sealed record Disconnected(Guid Connection, string? DeviceId, bool WasAuthenticated) : Event;
        /// <summary>新连接被限制策略拒绝（连接数、速率或封禁）。</summary>
        public sealed record Rejected(string Ip, string Reason) : Event;
    }

    public const string ServiceType = "_notibridge._tcp";
    public const int DefaultPort = 47800;

    private sealed class Session(Guid id, TcpClient tcp, WebSocket ws, SessionMachine machine, string ip)
    {
        public Guid Id { get; } = id;
        public string Ip { get; } = ip;
        public TcpClient Tcp { get; } = tcp;
        public WebSocket Ws { get; } = ws;
        public SessionMachine Machine { get; } = machine;
        public SemaphoreSlim SendLock { get; } = new(1, 1);
        public object MachineLock { get; } = new();
        public CancellationTokenSource Cts { get; } = new();
    }

    private readonly Func<SessionMachine> _makeMachine;
    private readonly ConcurrentDictionary<Guid, Session> _sessions = new();
    private readonly bool _loopbackOnly;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public event Action<Event>? OnEvent;

    /// <summary>防滥用策略（docs/protocol.md “电脑端连接限制”）。</summary>
    public ConnectionGuard Guard { get; }

    /// <param name="loopbackOnly">测试用：只监听 127.0.0.1。</param>
    public BridgeServer(Func<SessionMachine> makeMachine, ConnectionGuard.Limits? limits = null, bool loopbackOnly = false)
    {
        _makeMachine = makeMachine;
        _loopbackOnly = loopbackOnly;
        Guard = new ConnectionGuard(limits);
    }

    public int ConnectionCount => _sessions.Count;

    public int Port { get; private set; }

    public void Start(int port)
    {
        Stop();
        _cts = new CancellationTokenSource();
        try
        {
            TcpListener l;
            if (_loopbackOnly)
            {
                l = new TcpListener(IPAddress.Loopback, port);
                l.Start();
            }
            else try
            {
                l = new TcpListener(IPAddress.IPv6Any, port);
                l.Server.DualMode = true; // 同时接受 IPv4 / IPv6
                l.Start();
            }
            catch (SocketException)
            {
                // 系统禁用了 IPv6 时退回 IPv4
                l = new TcpListener(IPAddress.Any, port);
                l.Start();
            }
            _listener = l;
            Port = ((IPEndPoint)l.LocalEndpoint).Port;
        }
        catch (SocketException e)
        {
            OnEvent?.Invoke(new Event.Stopped($"无法监听端口 {port}：{e.Message}"));
            return;
        }
        OnEvent?.Invoke(new Event.Listening(Port));
        _ = AcceptLoop(_listener, _cts.Token);
    }

    public void Stop()
    {
        _cts?.Cancel();
        _listener?.Stop();
        _listener = null;
        foreach (var s in _sessions.Values) Abort(s);
    }

    public void Dispose() => Stop();

    public IEnumerable<Guid> AuthenticatedConnections =>
        _sessions.Values.Where(s => s.Machine.IsAuthenticated).Select(s => s.Id).ToList();

    public void Ack(int seq, string result, Guid conn)
    {
        if (!_sessions.TryGetValue(conn, out var s)) return;
        string? frame;
        lock (s.MachineLock) frame = s.Machine.Ack(seq, result);
        if (frame is not null) _ = SendRaw(s, frame);
    }

    /// <summary>发设置给某台手机；seq 为 null 表示电脑主动推送。</summary>
    public void SendSettings(SharedSettings st, int? seq, Guid conn)
    {
        if (!_sessions.TryGetValue(conn, out var s)) return;
        string? frame;
        lock (s.MachineLock) frame = s.Machine.SettingsFrame(st, seq);
        if (frame is not null) _ = SendRaw(s, frame);
    }

    /// <summary>把设置主动推送给所有在线手机（电脑上改了开关时）。</summary>
    public void BroadcastSettings(SharedSettings st)
    {
        foreach (var id in AuthenticatedConnections) SendSettings(st, null, id);
    }

    public void Disconnect(string deviceId)
    {
        foreach (var s in _sessions.Values.Where(s => s.Machine.DeviceId == deviceId)) Abort(s);
    }

    /// <summary>电脑上取消配对：手机在线时先发 unpair（手机随即删除这台电脑），稍后断开。返回是否已通知到在线手机。</summary>
    public bool Unpair(string deviceId)
    {
        var notified = false;
        foreach (var s in _sessions.Values.Where(s => s.Machine.DeviceId == deviceId).ToList())
        {
            string? frame;
            lock (s.MachineLock) frame = s.Machine.UnpairFrame();
            if (frame is null)
            {
                Abort(s);
                continue;
            }
            notified = true;
            _ = SendRaw(s, frame).ContinueWith(_ => Task.Delay(500).ContinueWith(_ => Abort(s)), TaskScheduler.Default);
        }
        return notified;
    }

    public void DisconnectAll()
    {
        foreach (var s in _sessions.Values) Abort(s);
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient tcp;
            try { tcp = await listener.AcceptTcpClientAsync(ct); }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException e)
            {
                OnEvent?.Invoke(new Event.Stopped($"监听失败：{e.Message}"));
                break;
            }
            string ip;
            try { ip = IpOf(tcp); }
            catch (Exception) { tcp.Dispose(); continue; }
            var verdict = Guard.Admit(ip);
            if (verdict != ConnectionGuard.Verdict.Allow)
            {
                tcp.Dispose();
                OnEvent?.Invoke(new Event.Rejected(ip, verdict switch
                {
                    ConnectionGuard.Verdict.TooManyConnections => "连接数已达上限",
                    ConnectionGuard.Verdict.RateLimited => "新连接过于频繁",
                    _ => "多次认证失败，暂时封禁",
                }));
                continue;
            }
            _ = HandleClient(tcp, ip, ct);
        }
    }

    internal static string IpOf(TcpClient tcp)
    {
        if (tcp.Client.RemoteEndPoint is not IPEndPoint ep) return "?";
        var a = ep.Address.IsIPv4MappedToIPv6 ? ep.Address.MapToIPv4() : ep.Address;
        var s = a.ToString();
        var pct = s.IndexOf('%'); // 去掉 IPv6 的接口后缀
        return pct >= 0 ? s[..pct] : s;
    }

    private async Task HandleClient(TcpClient tcp, string ip, CancellationToken serverCt)
    {
        tcp.NoDelay = true;
        var stream = tcp.GetStream();
        var started = DateTimeOffset.UtcNow;
        WebSocket ws;
        try
        {
            using var handshakeCts = CancellationTokenSource.CreateLinkedTokenSource(serverCt);
            handshakeCts.CancelAfter(Guard.Config.HandshakeTimeout);
            ws = await AcceptWebSocket(stream, handshakeCts.Token);
        }
        catch (Exception)
        {
            tcp.Dispose();
            Guard.ConnectionClosed();
            return;
        }
        var s = new Session(Guid.NewGuid(), tcp, ws, _makeMachine(), ip);
        _sessions[s.Id] = s;
        // 握手/认证超时：10 秒内必须完成认证；配对中放宽，给用户核对校验码
        var remaining = Guard.Config.HandshakeTimeout - (DateTimeOffset.UtcNow - started);
        _ = Task.Delay(remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero, s.Cts.Token).ContinueWith(async t =>
        {
            if (t.IsCanceled || s.Machine.IsAuthenticated) return;
            if (!s.Machine.IsPairing)
            {
                Abort(s);
                return;
            }
            try { await Task.Delay(Guard.Config.PairingTimeout - Guard.Config.HandshakeTimeout, s.Cts.Token); }
            catch (OperationCanceledException) { return; }
            if (!s.Machine.IsAuthenticated) Abort(s);
        }, TaskScheduler.Default);
        try
        {
            await ReceiveLoop(s);
        }
        finally
        {
            Drop(s);
        }
    }

    private async Task ReceiveLoop(Session s)
    {
        var buffer = new byte[16 * 1024];
        using var ms = new MemoryStream();
        while (s.Ws.State == WebSocketState.Open && !s.Cts.IsCancellationRequested)
        {
            ms.SetLength(0);
            WebSocketReceiveResult r;
            do
            {
                try { r = await s.Ws.ReceiveAsync(buffer, s.Cts.Token); }
                catch (Exception) { return; }
                if (r.MessageType == WebSocketMessageType.Close) return;
                ms.Write(buffer, 0, r.Count);
                if (ms.Length > Guard.MaxFrame(s.Machine.IsAuthenticated))
                {
                    // 认证前不接受大帧
                    Guard.RecordFailure(s.Ip);
                    OnEvent?.Invoke(new Event.Output(new SessionOutput.Log($"帧过大（>{ms.Length} 字节），已断开"), s.Id));
                    return;
                }
            } while (!r.EndOfMessage);
            if (r.MessageType != WebSocketMessageType.Text) continue;
            var text = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
            IReadOnlyList<SessionOutput> outs;
            lock (s.MachineLock) outs = s.Machine.Handle(text);
            foreach (var o in outs)
            {
                switch (o)
                {
                    case SessionOutput.Send send:
                        await SendRaw(s, send.Frame);
                        break;
                    case SessionOutput.Close c:
                        if (SessionMachine.FailureReasons.Contains(c.Reason)) Guard.RecordFailure(s.Ip);
                        // 让最后一帧先发出去再断开
                        _ = Task.Delay(300).ContinueWith(_ => Abort(s), TaskScheduler.Default);
                        break;
                    case SessionOutput.Authenticated:
                        Guard.RecordSuccess(s.Ip);
                        break;
                }
                OnEvent?.Invoke(new Event.Output(o, s.Id));
            }
        }
    }

    private static async Task SendRaw(Session s, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        await s.SendLock.WaitAsync();
        try
        {
            if (s.Ws.State == WebSocketState.Open)
                await s.Ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        }
        catch (Exception)
        {
            // 连接已断开，由接收循环清理
        }
        finally
        {
            s.SendLock.Release();
        }
    }

    private static void Abort(Session s)
    {
        try { s.Cts.Cancel(); } catch (ObjectDisposedException) { }
        try { s.Ws.Abort(); } catch (Exception) { }
        try { s.Tcp.Dispose(); } catch (Exception) { }
    }

    private void Drop(Session s)
    {
        if (!_sessions.TryRemove(s.Id, out _)) return;
        Guard.ConnectionClosed();
        Abort(s);
        s.Cts.Dispose();
        s.SendLock.Dispose();
        OnEvent?.Invoke(new Event.Disconnected(s.Id, s.Machine.DeviceId, s.Machine.IsAuthenticated));
    }

    /// <summary>读取 HTTP 升级请求并回 101，然后把流交给 .NET 的 WebSocket 实现。</summary>
    private static async Task<WebSocket> AcceptWebSocket(NetworkStream stream, CancellationToken ct)
    {
        var header = new StringBuilder();
        var one = new byte[1];
        while (true)
        {
            var n = await stream.ReadAsync(one, ct);
            if (n == 0) throw new IOException("closed during handshake");
            header.Append((char)one[0]);
            if (header.Length > 8192) throw new IOException("header too large");
            if (header.Length >= 4 && header[^1] == '\n' && header[^2] == '\r' && header[^3] == '\n' && header[^4] == '\r')
                break;
        }
        var lines = header.ToString().Split("\r\n");
        if (!lines[0].StartsWith("GET ", StringComparison.Ordinal)) throw new IOException("not GET");
        string? key = null;
        var upgrade = false;
        foreach (var line in lines.Skip(1))
        {
            var idx = line.IndexOf(':');
            if (idx <= 0) continue;
            var name = line[..idx].Trim();
            var value = line[(idx + 1)..].Trim();
            if (name.Equals("Sec-WebSocket-Key", StringComparison.OrdinalIgnoreCase)) key = value;
            if (name.Equals("Upgrade", StringComparison.OrdinalIgnoreCase) &&
                value.Equals("websocket", StringComparison.OrdinalIgnoreCase)) upgrade = true;
        }
        if (!upgrade || key is null)
        {
            var bad = Encoding.ASCII.GetBytes("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
            await stream.WriteAsync(bad, ct);
            throw new IOException("not a websocket upgrade");
        }
        var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        var resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                   $"Sec-WebSocket-Accept: {accept}\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(resp), ct);
        return WebSocket.CreateFromStream(stream, new WebSocketCreationOptions
        {
            IsServer = true,
            KeepAliveInterval = TimeSpan.FromSeconds(30),
        });
    }
}
