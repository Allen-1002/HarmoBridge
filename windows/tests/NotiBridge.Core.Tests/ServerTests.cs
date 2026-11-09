using System.Net.WebSockets;
using System.Text;
using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

/// <summary>端到端：真实 TCP + WebSocket（只监听 127.0.0.1），模拟手机连接同一台电脑。</summary>
public class ServerTests
{
    private static async Task<Envelope> Recv(ClientWebSocket ws, int seconds = 5)
    {
        var buf = new byte[64 * 1024];
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        var r = await ws.ReceiveAsync(buf, cts.Token);
        if (r.MessageType == WebSocketMessageType.Close) throw new WebSocketException("closed");
        return Envelope.Parse(Encoding.UTF8.GetString(buf, 0, r.Count))!;
    }

    private static Task Send(ClientWebSocket ws, string text) =>
        ws.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, CancellationToken.None);

    private static async Task<ClientWebSocket> Connect(int port)
    {
        var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}"), CancellationToken.None);
        return ws;
    }

    /// <summary>连接被服务器拒绝或断开（握手失败、读到 Close 或连接中断）。</summary>
    private static async Task<bool> IsClosedByServer(int port, string? first = null, int seconds = 5)
    {
        try
        {
            using var ws = await Connect(port);
            if (first is not null) await Send(ws, first);
            var buf = new byte[64 * 1024];
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
            while (true)
            {
                var r = await ws.ReceiveAsync(buf, cts.Token);
                if (r.MessageType == WebSocketMessageType.Close) return true;
            }
        }
        catch (OperationCanceledException) { return false; }
        catch (WebSocketException) { return true; }
        catch (IOException) { return true; }
        catch (System.Net.Http.HttpRequestException) { return true; }
    }

    private static BridgeServer NewServer(MemoryStore store, PairingWindow w, ConnectionGuard.Limits? limits = null)
    {
        var server = new BridgeServer(() => new SessionMachine(store, w, "pc", "PC"), limits, loopbackOnly: true);
        server.OnEvent += e =>
        {
            if (e is BridgeServer.Event.Output { Value: SessionOutput.Notify n } o) server.Ack(n.Seq, "shown", o.Connection);
        };
        server.Start(0);
        Assert.True(server.Port > 0);
        return server;
    }

    private static async Task PairOverNetwork(PhoneSim p, int port, PairingWindow w)
    {
        w.Open();
        using var ws = await Connect(port);
        await Send(ws, p.PairReq());
        var chal = await Recv(ws);
        Assert.Equal("pair_chal", chal.T);
        await Send(ws, p.PairKey(chal, w.ActivePin()!));
        await Send(ws, p.PairConfirm());
        Assert.True(p.AcceptPairOk(await Recv(ws)));
    }

    private static async Task<ClientWebSocket> Login(PhoneSim p, int port)
    {
        var ws = await Connect(port);
        await Send(ws, p.Hello());
        await Send(ws, p.Auth(await Recv(ws)));
        Assert.True(p.CheckAuthOk(await Recv(ws)));
        return ws;
    }

    private static readonly ConnectionGuard.Limits Relaxed = new() { MaxNewPerMinutePerIp = 1000 };

    [Fact]
    public async Task TwoPhonesPairConnectAndNotify()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        using var server = NewServer(store, w, Relaxed);
        var events = new List<BridgeServer.Event>();
        server.OnEvent += e => { lock (events) events.Add(e); };
        var phones = new[] { new PhoneSim("A"), new PhoneSim("B", platform: "harmony") };
        foreach (var p in phones) await PairOverNetwork(p, server.Port, w);
        var sockets = new List<ClientWebSocket>();
        foreach (var p in phones) sockets.Add(await Login(p, server.Port));
        Assert.Equal(2, server.AuthenticatedConnections.Count());
        for (var i = 0; i < 2; i++)
        {
            await Send(sockets[i], phones[i].Notify("same-hash"));
            Assert.Equal("shown", phones[i].Receive(await Recv(sockets[i]))!.Result);
        }
        server.BroadcastSettings(new SharedSettings(true, true, true, 42));
        for (var i = 0; i < 2; i++) Assert.True(phones[i].Receive(await Recv(sockets[i]))!.Paused);
        server.Disconnect("A");
        await Task.Delay(300);
        Assert.Single(server.AuthenticatedConnections);
        lock (events) Assert.Contains(events, e => e is BridgeServer.Event.Disconnected { DeviceId: "A", WasAuthenticated: true });
        foreach (var s in sockets) s.Dispose();
    }

    [Fact]
    public async Task RejectsPlainHttp()
    {
        using var server = NewServer(new MemoryStore(), new PairingWindow());
        using var http = new HttpClient(new HttpClientHandler { UseProxy = false });
        var r = await http.GetAsync($"http://127.0.0.1:{server.Port}/");
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, r.StatusCode);
    }

    [Fact]
    public async Task OversizedFrameBeforeAuthDisconnects()
    {
        using var server = NewServer(new MemoryStore(), new PairingWindow());
        Assert.True(await IsClosedByServer(server.Port, "{\"t\":\"hello\",\"pad\":\"" + new string('x', 20_000) + "\"}"));
        Assert.Equal(1, server.Guard.FailureCount("127.0.0.1"));
    }

    [Fact]
    public async Task HandshakeTimeoutClosesIdleConnection()
    {
        using var server = NewServer(new MemoryStore(), new PairingWindow(),
            new ConnectionGuard.Limits { HandshakeTimeout = TimeSpan.FromMilliseconds(500) });
        Assert.True(await IsClosedByServer(server.Port, null, 4));
    }

    [Fact]
    public async Task PerIpRateLimit()
    {
        using var server = NewServer(new MemoryStore(), new PairingWindow(), new ConnectionGuard.Limits { MaxNewPerMinutePerIp = 3 });
        var open = new List<ClientWebSocket>();
        for (var i = 0; i < 3; i++) open.Add(await Connect(server.Port));
        Assert.True(await IsClosedByServer(server.Port));
        foreach (var s in open) s.Dispose();
    }

    [Fact]
    public async Task ConnectionCap()
    {
        using var server = NewServer(new MemoryStore(), new PairingWindow(), new ConnectionGuard.Limits { MaxConnections = 2, MaxNewPerMinutePerIp = 100 });
        using var a = await Connect(server.Port);
        using var b = await Connect(server.Port);
        Assert.True(await IsClosedByServer(server.Port));
    }

    [Fact]
    public async Task LockoutAfterRepeatedFailures()
    {
        using var server = NewServer(new MemoryStore(), new PairingWindow());
        for (var i = 0; i < 3; i++) Assert.True(await IsClosedByServer(server.Port, "garbage"));
        Assert.Equal(3, server.Guard.FailureCount("127.0.0.1"));
        Assert.True(await IsClosedByServer(server.Port, new PhoneSim("x").Hello()));
        Assert.NotNull(server.Guard.LockedUntil("127.0.0.1"));
    }

    [Fact]
    public async Task AbruptDisconnectFreesSession()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        using var server = NewServer(store, w, Relaxed);
        var gone = new TaskCompletionSource();
        server.OnEvent += e => { if (e is BridgeServer.Event.Disconnected { DeviceId: "A", WasAuthenticated: true }) gone.TrySetResult(); };
        var p = new PhoneSim("A");
        await PairOverNetwork(p, server.Port, w);
        var ws = await Login(p, server.Port);
        await Send(ws, p.Notify("1"));
        await Recv(ws);
        ws.Abort(); // 不发 Close 帧，直接断开
        ws.Dispose();
        await gone.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Task.Delay(100);
        Assert.Equal(0, server.ConnectionCount);
        Assert.Equal(0, server.Guard.OpenConnections);
    }

    /// <summary>多台手机同时在线、高频发通知：每条都收到 ack、cseq 严格递增。</summary>
    [Fact]
    public async Task ConcurrentPhonesHighRateStress()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        using var server = NewServer(store, w, Relaxed);
        var phones = Enumerable.Range(0, 8).Select(i => new PhoneSim($"P{i}")).ToList();
        foreach (var p in phones) await PairOverNetwork(p, server.Port, w);
        const int perPhone = 200;
        var totals = await Task.WhenAll(phones.Select(async p =>
        {
            using var ws = await Login(p, server.Port);
            var sender = Task.Run(async () => { for (var i = 0; i < perPhone; i++) await Send(ws, p.Notify($"n{i}", $"t{i}")); });
            var acks = 0;
            while (acks < perPhone)
            {
                var inner = p.Receive(await Recv(ws, 15));
                Assert.NotNull(inner);
                Assert.Equal("ack", inner!.Kind);
                acks++;
            }
            await sender;
            return acks;
        }));
        Assert.Equal(phones.Count * perPhone, totals.Sum());
    }
}
