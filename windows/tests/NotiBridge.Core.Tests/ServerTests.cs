using System.Net.WebSockets;
using System.Text;
using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

/// <summary>端到端：真实 TCP + WebSocket，两台模拟手机同时连接同一台电脑。</summary>
public class ServerTests
{
    private static async Task<Envelope> Recv(ClientWebSocket ws)
    {
        var buf = new byte[64 * 1024];
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var r = await ws.ReceiveAsync(buf, cts.Token);
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

    [Fact]
    public async Task TwoPhonesPairConnectAndNotify()
    {
        var store = new MemoryStore();
        var window = new PairingWindow();
        using var server = new BridgeServer(() => new SessionMachine(store, window, "pc", "PC"));
        var events = new List<BridgeServer.Event>();
        server.OnEvent += e =>
        {
            lock (events) events.Add(e);
            if (e is BridgeServer.Event.Output { Value: SessionOutput.Notify n } o) server.Ack(n.Seq, "shown", o.Connection);
        };
        server.Start(0);
        Assert.True(server.Port > 0);

        var phones = new[] { new PhoneSim("A"), new PhoneSim("B") };
        foreach (var p in phones)
        {
            window.Open();
            using var ws = await Connect(server.Port);
            await Send(ws, p.PairReq());
            var chal = await Recv(ws);
            Assert.Equal("pair_chal", chal.T);
            await Send(ws, p.PairConfirm(chal, window.ActivePin()!));
            Assert.Equal("pair_ok", (await Recv(ws)).T);
        }

        var sockets = new List<ClientWebSocket>();
        foreach (var p in phones)
        {
            var ws = await Connect(server.Port);
            sockets.Add(ws);
            await Send(ws, p.Hello());
            await Send(ws, p.Auth(await Recv(ws)));
            Assert.Equal("auth_ok", (await Recv(ws)).T);
        }
        Assert.Equal(2, server.AuthenticatedConnections.Count());

        for (var i = 0; i < 2; i++)
        {
            await Send(sockets[i], phones[i].Notify("same-hash"));
            var ack = phones[i].OpenInner(await Recv(sockets[i]));
            Assert.Equal("ack", ack.Kind);
            Assert.Equal("shown", ack.Result);
        }

        // 电脑主动推送设置给所有在线手机
        server.BroadcastSettings(new SharedSettings(true, true, true, 42));
        for (var i = 0; i < 2; i++)
        {
            var st = phones[i].OpenInner(await Recv(sockets[i]));
            Assert.Equal("settings", st.Kind);
            Assert.True(st.Paused);
        }

        // 只断开 A，B 仍在线
        server.Disconnect("A");
        await Task.Delay(300);
        Assert.Single(server.AuthenticatedConnections);
        lock (events) Assert.Contains(events, e => e is BridgeServer.Event.Disconnected { DeviceId: "A", WasAuthenticated: true });
        foreach (var s in sockets) s.Dispose();
    }

    [Fact]
    public async Task RejectsPlainHttp()
    {
        using var server = new BridgeServer(() => new SessionMachine(new MemoryStore(), new PairingWindow(), "pc", "PC"));
        server.Start(0);
        using var http = new HttpClient(new HttpClientHandler { UseProxy = false });
        var r = await http.GetAsync($"http://127.0.0.1:{server.Port}/");
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, r.StatusCode);
    }
}
