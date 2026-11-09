using HarmoBridge.Core;
using Xunit;

namespace HarmoBridge.Core.Tests;

/// <summary>与 mac/Tests/HarmoBridgeCoreTests/SessionMachineTests.swift 覆盖相同的协议场景。</summary>
public class SessionMachineTests
{
    private static Envelope Sent(IReadOnlyList<SessionOutput> outs) =>
        Envelope.Parse(outs.OfType<SessionOutput.Send>().First().Frame)!;

    private static SessionMachine NewMachine(MemoryStore store, PairingWindow w) => new(store, w, "pc-id", "PC");

    private static PhoneSim PairPhone(MemoryStore store, PairingWindow w, string deviceId, string? pin = null)
    {
        w.Open();
        var phone = new PhoneSim(deviceId);
        var m = NewMachine(store, w);
        var chal = Sent(m.Handle(phone.PairReq()));
        Assert.Equal("pair_chal", chal.T);
        Assert.Equal("windows", chal.Platform);
        Assert.Equal("pc-id", chal.MacId);
        var outs = m.Handle(phone.PairConfirm(chal, pin ?? w.ActivePin()!));
        var ok = Sent(outs);
        Assert.Equal("pair_ok", ok.T);
        Assert.Equal("pair-confirm-mac", BridgeCrypto.Open(phone.Key!, ok.Box!));
        Assert.Contains(outs, o => o is SessionOutput.Paired p && p.DeviceId == deviceId);
        return phone;
    }

    private static (SessionMachine, PhoneSim) Online(MemoryStore store, PairingWindow w, PhoneSim phone)
    {
        var m = NewMachine(store, w);
        var chal = Sent(m.Handle(phone.Hello()));
        Assert.Equal("challenge", chal.T);
        var authOk = Sent(m.Handle(phone.Auth(chal)));
        Assert.Equal("auth_ok", authOk.T);
        Assert.Equal($"ok|{phone.Sid}|{phone.PhoneNonce}", BridgeCrypto.Open(phone.Key!, authOk.Box!));
        Assert.True(m.IsAuthenticated);
        return (m, phone);
    }

    [Fact]
    public void PairAuthNotifyAndReplay()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "dev1");
        Assert.True(store.Keys.ContainsKey("dev1"));
        Assert.Null(w.ActivePin()); // 配对成功后 PIN 必须作废

        var (m, _) = Online(store, w, phone);
        var frame = phone.Notify("h1");
        var r = m.Handle(frame);
        var n = Assert.IsType<SessionOutput.Notify>(r[0]);
        Assert.Equal("h1", n.Notification.Id);
        Assert.Equal(1, n.Seq);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_000), n.Notification.Time);

        // ack 可被手机解密，sid 一致
        var ack = phone.OpenInner(Envelope.Parse(m.Ack(1, "shown")!)!);
        Assert.Equal("ack", ack.Kind);
        Assert.Equal("shown", ack.Result);
        Assert.Equal(phone.Sid, ack.Sid);

        // 重放同一帧 → 拒绝并断开
        var replay = m.Handle(frame);
        Assert.Contains(replay, o => o is SessionOutput.Close c && c.Reason == "replay");
        Assert.False(m.IsAuthenticated);
    }

    [Fact]
    public void WrongPinCountsFailuresAndClosesWindow()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        w.Open();
        for (var i = 1; i <= 3; i++)
        {
            var phone = new PhoneSim("dev1");
            var m = NewMachine(store, w);
            var chal = Sent(m.Handle(phone.PairReq()));
            if (i == 1) Assert.Equal("pair_chal", chal.T);
            if (chal.T != "pair_chal") break;
            var outs = m.Handle(phone.PairConfirm(chal, "999999" == w.ActivePin() ? "999998" : "999999"));
            Assert.Contains(outs, o => o is SessionOutput.Close c && c.Reason == "bad_pin");
        }
        Assert.Empty(store.Keys);
        Assert.Null(w.ActivePin());
    }

    [Fact]
    public void InfoProbeReturnsIdentityAndCloses()
    {
        var m = NewMachine(new MemoryStore(), new PairingWindow());
        var outs = m.Handle(new Envelope { T = "info" }.ToJson());
        var info = Sent(outs);
        Assert.Equal("info", info.T);
        Assert.Equal("pc-id", info.MacId);
        Assert.Equal("windows", info.Platform);
        Assert.Null(info.Pub);
        Assert.Contains(outs, o => o is SessionOutput.Close c && c.Reason == "info");
        Assert.Empty(m.Handle(new PhoneSim("x").Hello()));
    }

    [Fact]
    public void PairingClosedAndUnknownDevice()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var m = NewMachine(store, w);
        Assert.Contains(m.Handle(new PhoneSim("x").PairReq()), o => o is SessionOutput.Close c && c.Reason == "pairing_closed");
        var m2 = NewMachine(store, w);
        Assert.Contains(m2.Handle(new PhoneSim("ghost").Hello()), o => o is SessionOutput.Close c && c.Reason == "unknown_device");
    }

    [Fact]
    public void WrongKeyFailsAuth()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "dev1");
        phone.Key = BridgeCrypto.RandomBytes(32);
        var m = NewMachine(store, w);
        var chal = Sent(m.Handle(phone.Hello()));
        Assert.Contains(m.Handle(phone.Auth(chal)), o => o is SessionOutput.Close c && c.Reason == "auth_failed");
    }

    [Fact]
    public void BusinessMessageBeforeAuthIsRejected()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "dev1");
        var m = NewMachine(store, w);
        phone.Sid = "fake";
        Assert.Contains(m.Handle(phone.Notify("h")), o => o is SessionOutput.Close);
    }

    [Fact]
    public void OtpSettingsCancelAndPushedSettings()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var (m, phone) = Online(store, w, PairPhone(store, w, "dev1"));
        var otp = m.Handle(phone.Msg(new Inner { Kind = "otp", Sid = phone.Sid, Seq = ++phone.Seq, Id = "o", BundleName = "com.ohos.mms", Code = "482913" }));
        Assert.Equal("482913", Assert.IsType<SessionOutput.Otp>(otp[0]).Code.Code);
        var badOtp = m.Handle(phone.Msg(new Inner { Kind = "otp", Sid = phone.Sid, Seq = ++phone.Seq, Code = "12ab" }));
        Assert.IsType<SessionOutput.Log>(badOtp[0]);
        var st = m.Handle(phone.Msg(new Inner { Kind = "settings", Sid = phone.Sid, Seq = ++phone.Seq, Paused = true, BlockSensitive = false, CopyOtp = true, UpdatedAt = 5 }));
        Assert.Equal(new SharedSettings(true, false, true, 5), Assert.IsType<SessionOutput.Settings>(st[0]).Value);
        var cancel = m.Handle(phone.Msg(new Inner { Kind = "cancel", Sid = phone.Sid, Seq = ++phone.Seq, Ids = ["a", "b"] }));
        Assert.Equal(["a", "b"], Assert.IsType<SessionOutput.Cancel>(cancel[0]).Ids);
        // 电脑主动推送设置：手机能解密
        var pushed = phone.OpenInner(Envelope.Parse(m.SettingsFrame(new SharedSettings(false, true, false, 9))!)!);
        Assert.Equal("settings", pushed.Kind);
        Assert.Equal(9, pushed.UpdatedAt);
        Assert.False(pushed.CopyOtp);
        // call.* 预留：忽略
        Assert.IsType<SessionOutput.Log>(m.Handle(phone.Msg(new Inner { Kind = "call.dial", Sid = phone.Sid, Seq = ++phone.Seq }))[0]);
    }

    [Fact]
    public void MultiplePhonesHaveIndependentKeys()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var a = PairPhone(store, w, "phoneA");
        var b = PairPhone(store, w, "phoneB");
        Assert.NotEqual(store.Keys["phoneA"], store.Keys["phoneB"]);
        Online(store, w, a);
        Online(store, w, b);
    }

    [Fact]
    public void SettingsMergeIsLastWriterWins()
    {
        var local = new SharedSettings(false, true, true, 10);
        Assert.Equal(local, local.Merged(new SharedSettings(true, true, true, 9)));
        var newer = new SharedSettings(true, false, false, 11);
        Assert.Equal(newer, local.Merged(newer));
    }

    [Fact]
    public void FilterAndDeduper()
    {
        var f = new SyncFilter();
        Assert.NotNull(f.Decide("com.x", "您的验证码", ""));
        Assert.Null(f.Decide("com.x", "hello", "world"));
        f.Blacklist.Add("com.x");
        Assert.Equal("黑名单应用", f.Decide("com.x", "hello", ""));
        f.Mode = SyncFilter.FilterMode.WhitelistOnly;
        Assert.Equal("不在白名单", f.Decide("com.y", "hello", ""));

        var d = new NotificationDeduper();
        Assert.Equal(NotificationDeduper.Result.New, d.Check("p1|h", "t", "x"));
        Assert.Equal(NotificationDeduper.Result.Duplicate, d.Check("p1|h", "t", "x"));
        Assert.Equal(NotificationDeduper.Result.Updated, d.Check("p1|h", "t", "y"));
        Assert.Equal(NotificationDeduper.Result.New, d.Check("p2|h", "t", "x")); // 不同手机同一 hashCode 互不影响
    }
}
