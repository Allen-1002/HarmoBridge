using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

/// <summary>与 mac/Tests/NotiBridgeCoreTests/SessionMachineTests.swift 覆盖相同的协议 v2 场景。</summary>
public class SessionMachineTests
{
    private static Envelope Sent(IReadOnlyList<SessionOutput> outs) =>
        Envelope.Parse(outs.OfType<SessionOutput.Send>().First().Frame)!;

    private static SessionMachine NewMachine(MemoryStore store, PairingWindow w) => new(store, w, "pc-id", "PC");

    /// <summary>走完配对的前三步，返回最后 pair_confirm 的输出。</summary>
    private static IReadOnlyList<SessionOutput> Pair(PhoneSim phone, MemoryStore store, PairingWindow w, string pin)
    {
        var m = NewMachine(store, w);
        var chal = Sent(m.Handle(phone.PairReq()));
        Assert.Equal("pair_chal", chal.T);
        Assert.Equal(2, chal.V);
        Assert.Equal("windows", chal.Platform);
        var started = m.Handle(phone.PairKey(chal, pin));
        var sas = Assert.IsType<SessionOutput.PairingStarted>(Assert.Single(started));
        Assert.Equal(phone.Keys!.Sas, sas.Sas);
        return m.Handle(phone.PairConfirm());
    }

    private static PhoneSim PairPhone(MemoryStore store, PairingWindow w, string deviceId)
    {
        w.Open();
        var phone = new PhoneSim(deviceId);
        var outs = Pair(phone, store, w, w.ActivePin()!);
        Assert.True(phone.AcceptPairOk(Sent(outs)));
        Assert.Contains(outs, o => o is SessionOutput.Paired p && p.DeviceId == deviceId);
        Assert.Null(w.ActivePin());
        return phone;
    }

    private static SessionMachine Online(MemoryStore store, PairingWindow w, PhoneSim phone)
    {
        var m = NewMachine(store, w);
        var chal = Sent(m.Handle(phone.Hello()));
        Assert.Equal("challenge", chal.T);
        Assert.Equal(2, chal.V);
        Assert.True(phone.CheckAuthOk(Sent(m.Handle(phone.Auth(chal)))));
        Assert.True(m.IsAuthenticated);
        return m;
    }

    [Fact]
    public void PairAuthNotifyAndReplay()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "A");
        Assert.Equal(phone.Key, store.Keys["A"]);
        var m = Online(store, w, phone);
        var frame = phone.Notify("h1");
        var n = Assert.IsType<SessionOutput.Notify>(m.Handle(frame).First());
        Assert.Equal("h1", n.Notification.Id);
        Assert.Equal(1, n.Seq);
        Assert.Contains(m.Handle(frame), o => o is SessionOutput.Close { Reason: "replay" });
    }

    [Fact]
    public void ComputerFramesCarryIncreasingCseqAndPhoneRejectsReplay()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "A");
        var m = Online(store, w, phone);
        var a1 = Envelope.Parse(m.Ack(1, "shown")!)!;
        var a2 = Envelope.Parse(m.SettingsFrame(new SharedSettings(false, true, true, 1))!)!;
        var a3 = Envelope.Parse(m.UnpairFrame()!)!;
        Assert.Equal(1, phone.Receive(a1)!.Cseq);
        Assert.Equal(2, phone.Receive(a2)!.Cseq);
        Assert.Null(phone.Receive(a1));
        Assert.Null(phone.Receive(a2));
        Assert.Equal("unpair", phone.Receive(a3)!.Kind);
        Assert.Null(phone.Receive(a3));
        // 反射回电脑：方向 AAD 不同，解不开
        Assert.Contains(m.Handle(a2.ToJson()), o => o is SessionOutput.Close { Reason: "bad_msg" });
    }

    [Fact]
    public void WrongPinCountsFailuresAndClosesWindow()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        w.Open();
        var wrong = w.ActivePin() == "000000" ? "111111" : "000000";
        for (var i = 1; i <= 3; i++)
        {
            Assert.Equal("bad_pin", Sent(Pair(new PhoneSim("x"), store, w, wrong)).Code);
            Assert.Equal(i, w.Failures);
        }
        Assert.Null(w.ActivePin());
        Assert.Empty(store.Keys);
        Assert.Equal("pairing_closed", Sent(NewMachine(store, w).Handle(new PhoneSim("y").PairReq())).Code);
    }

    [Fact]
    public void ForgedConfirmMacRejected()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        w.Open();
        var phone = new PhoneSim("d");
        var m = NewMachine(store, w);
        m.Handle(phone.PairKey(Sent(m.Handle(phone.PairReq())), w.ActivePin()!));
        var forged = new Envelope { T = "pair_confirm", Confirm = Convert.ToBase64String(BridgeCrypto.RandomBytes(32)) }.ToJson();
        Assert.Equal("bad_pin", Sent(m.Handle(forged)).Code);
        Assert.Equal(1, w.Failures);
        Assert.Empty(store.Keys);
    }

    [Fact]
    public void ReplayedPairMessagesRejected()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        w.Open();
        var pin = w.ActivePin()!;
        var phone = new PhoneSim("d");
        var m1 = NewMachine(store, w);
        var key = phone.PairKey(Sent(m1.Handle(phone.PairReq())), pin);
        var confirm = phone.PairConfirm();
        // 新连接里重放录下的 pair_key / pair_confirm：电脑 nonce 与 Yb 每次不同，确认码对不上
        var m2 = NewMachine(store, w);
        var replayReq = new Envelope
        {
            T = "pair_req", V = 2, DeviceId = "d", DeviceName = "Phone", Platform = "android",
            Nonce = Convert.ToBase64String(phone.PhoneNonce),
        }.ToJson();
        Assert.Equal("pair_chal", Sent(m2.Handle(replayReq)).T);
        m2.Handle(key);
        Assert.Equal("bad_pin", Sent(m2.Handle(confirm)).Code);
        Assert.Empty(store.Keys);
        // 同一连接重复 pair_key：非法
        var m3 = NewMachine(store, w);
        var p3 = new PhoneSim("e");
        var k3 = p3.PairKey(Sent(m3.Handle(p3.PairReq())), pin);
        m3.Handle(k3);
        Assert.Equal("unexpected", Sent(m3.Handle(k3)).Code);
    }

    [Fact]
    public void LowOrderPointsAbortPairing()
    {
        var bad = TestVectors.Load().GetProperty("cpaceOfficial").GetProperty("lowOrder").EnumerateArray()
            .Where(x => x.GetProperty("mustAbort").GetBoolean()).ToList();
        Assert.NotEmpty(bad);
        var store = new MemoryStore();
        foreach (var item in bad)
        {
            var w = new PairingWindow();
            w.Open();
            var m = NewMachine(store, w);
            m.Handle(new PhoneSim("d").PairReq());
            var outs = m.Handle(new Envelope { T = "pair_key", Pub = Convert.ToBase64String(item.Hex("u")) }.ToJson());
            Assert.Equal("bad_point", Sent(outs).Code);
            Assert.Equal(1, w.Failures);
        }
        Assert.Empty(store.Keys);
    }

    [Fact]
    public void PhoneRejectsImpostorComputer()
    {
        var w = new PairingWindow();
        w.Open();
        var phone = new PhoneSim("d");
        var m = NewMachine(new MemoryStore(), w);
        phone.PairKey(Sent(m.Handle(phone.PairReq())), w.ActivePin() == "999999" ? "888888" : "999999");
        Assert.False(phone.AcceptPairOk(new Envelope { T = "pair_ok", Confirm = Convert.ToBase64String(BridgeCrypto.RandomBytes(32)) }));
        Assert.Null(phone.Key);
    }

    [Fact]
    public void PinExpiredBetweenChallengeAndConfirm()
    {
        var w = new PairingWindow(TimeSpan.FromMinutes(2));
        var t0 = DateTimeOffset.UtcNow;
        w.Open(t0);
        var store = new MemoryStore();
        var phone = new PhoneSim("d");
        var m = NewMachine(store, w);
        m.Handle(phone.PairKey(Sent(m.Handle(phone.PairReq(), t0)), w.ActivePin(t0)!), t0);
        Assert.Equal("pairing_closed", Sent(m.Handle(phone.PairConfirm(), t0.AddSeconds(121))).Code);
        Assert.Empty(store.Keys);
    }

    [Fact]
    public void OldVersionPeersGetUpgradeRequired()
    {
        var w = new PairingWindow();
        w.Open();
        foreach (var frame in new[] { new PhoneSim("d").PairReq(null), new PhoneSim("d").Hello(null), new PhoneSim("d").Hello(1) })
        {
            var outs = NewMachine(new MemoryStore(), w).Handle(frame);
            Assert.Equal("upgrade_required", Sent(outs).Code);
            Assert.Contains(outs, o => o is SessionOutput.PeerOutdated);
        }
    }

    [Fact]
    public void IllegalMessages()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        Assert.Contains(NewMachine(store, w).Handle("not json"), o => o is SessionOutput.Close { Reason: "bad_frame" });
        Assert.Contains(NewMachine(store, w).Handle("{\"x\":1}"), o => o is SessionOutput.Close { Reason: "bad_frame" });
        Assert.Contains(NewMachine(store, w).Handle("{\"t\":\"msg\",\"box\":\"AAAA\"}"), o => o is SessionOutput.Close { Reason: "unexpected" });
        Assert.Equal("bad_hello", Sent(NewMachine(store, w).Handle(new Envelope { T = "hello", V = 2, DeviceId = "d", Nonce = "short" }.ToJson())).Code);
        w.Open();
        Assert.Equal("bad_pair_req", Sent(NewMachine(store, w).Handle(new Envelope { T = "pair_req", V = 2, DeviceId = "d", Nonce = "AAAA" }.ToJson())).Code);
        Assert.Equal("bad_pair_req", Sent(NewMachine(store, w).Handle(new Envelope
        {
            T = "pair_req", V = 2, DeviceId = "d", DeviceName = new string('长', 65), Nonce = Convert.ToBase64String(BridgeCrypto.RandomBytes(16)),
        }.ToJson())).Code);

        var phone = PairPhone(store, w, "A");
        var m = NewMachine(store, w);
        var chal = Sent(m.Handle(phone.Hello()));
        phone.Auth(chal);
        var wrongDir = new Envelope { T = "auth", Box = BridgeCrypto.Seal(phone.Key!, $"auth|{phone.AuthNonce}|{phone.Sid}", BridgeCrypto.Direction.ToPhone) };
        Assert.Contains(m.Handle(wrongDir.ToJson()), o => o is SessionOutput.Close { Reason: "auth_failed" });

        var m2 = Online(store, w, phone);
        Assert.Contains(m2.Handle(phone.Msg(new Inner { Kind = "ping", Sid = "other", Seq = 1 })), o => o is SessionOutput.Close { Reason: "replay" });
        var m3 = Online(store, w, phone);
        m3.Handle(phone.Msg(new Inner { Kind = "ping", Sid = phone.Sid, Seq = 5 }));
        Assert.Contains(m3.Handle(phone.Msg(new Inner { Kind = "ping", Sid = phone.Sid, Seq = 5 })), o => o is SessionOutput.Close { Reason: "replay" });
        var m4 = Online(store, w, phone);
        Assert.Contains(m4.Handle(new Envelope { T = "msg", Box = new string('A', 40) }.ToJson()), o => o is SessionOutput.Close { Reason: "bad_msg" });
        Assert.Empty(m4.Handle(phone.Notify("after-close")));
        var m5 = Online(store, w, phone);
        phone.Seq++;
        Assert.IsType<SessionOutput.Log>(m5.Handle(phone.Msg(new Inner { Kind = "otp", Sid = phone.Sid, Seq = phone.Seq, Code = "１２３４" })).First());
    }

    [Fact]
    public void InfoProbeReturnsIdentityAndCloses()
    {
        var outs = NewMachine(new MemoryStore(), new PairingWindow()).Handle(new Envelope { T = "info" }.ToJson());
        var info = Sent(outs);
        Assert.Equal("info", info.T);
        Assert.Equal(2, info.V);
        Assert.Equal("pc-id", info.MacId);
        Assert.Equal("windows", info.Platform);
        Assert.Contains(outs, o => o is SessionOutput.Close { Reason: "info" });
    }

    [Fact]
    public void UnknownDeviceDoesNotCarryComputerId()
    {
        var outs = NewMachine(new MemoryStore(), new PairingWindow()).Handle(new PhoneSim("x").Hello());
        var err = Sent(outs);
        Assert.Equal("unknown_device", err.Code);
        Assert.Null(err.MacId);
    }

    [Fact]
    public void OtpSettingsCancelAndPushedSettings()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "A");
        var m = Online(store, w, phone);
        var otp = Assert.IsType<SessionOutput.Otp>(m.Handle(phone.Msg(new Inner { Kind = "otp", Sid = phone.Sid, Seq = ++phone.Seq, Id = "1", BundleName = "sms", Code = "123456" })).First());
        Assert.Equal("123456", otp.Code.Code);
        var st = Assert.IsType<SessionOutput.Settings>(m.Handle(phone.Msg(new Inner { Kind = "settings", Sid = phone.Sid, Seq = ++phone.Seq, Paused = true, BlockSensitive = false, CopyOtp = false, UpdatedAt = 5 })).First());
        Assert.Equal(new SharedSettings(true, false, false, 5), st.Value);
        var back = phone.Receive(Envelope.Parse(m.SettingsFrame(st.Value, st.Seq)!)!)!;
        Assert.Equal(st.Seq, back.Seq);
        Assert.True(back.Paused);
        var c = Assert.IsType<SessionOutput.Cancel>(m.Handle(phone.Msg(new Inner { Kind = "cancel", Sid = phone.Sid, Seq = ++phone.Seq, Ids = ["a", "b"] })).First());
        Assert.Equal(["a", "b"], c.Ids);
    }

    [Fact]
    public void PhoneUnpairRemovesKeyAcksAndCloses()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "A");
        var m = Online(store, w, phone);
        var outs = m.Handle(phone.Msg(new Inner { Kind = "unpair", Sid = phone.Sid, Seq = 1 }));
        Assert.Contains(outs, o => o is SessionOutput.Unpaired { DeviceId: "A" });
        Assert.Contains(outs, o => o is SessionOutput.Close { Reason: "unpaired" });
        Assert.False(store.Keys.ContainsKey("A"));
        var ack = phone.Receive(Sent(outs))!;
        Assert.Equal("unpaired", ack.Result);
        Assert.Equal(1, ack.Seq);
        Assert.Equal("unknown_device", Sent(NewMachine(store, w).Handle(phone.Hello())).Code);
    }

    [Fact]
    public void UnpairWithWrongSidIsRejected()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "A");
        var m = Online(store, w, phone);
        Assert.Contains(m.Handle(phone.Msg(new Inner { Kind = "unpair", Sid = "x", Seq = 1 })), o => o is SessionOutput.Close { Reason: "replay" });
        Assert.True(store.Keys.ContainsKey("A"));
    }

    [Fact]
    public void ComputerUnpairFrameOnlyWhenAuthenticated()
    {
        Assert.Null(NewMachine(new MemoryStore(), new PairingWindow()).UnpairFrame());
        var store = new MemoryStore();
        var w = new PairingWindow();
        var phone = PairPhone(store, w, "A");
        var inner = phone.Receive(Envelope.Parse(Online(store, w, phone).UnpairFrame()!)!)!;
        Assert.Equal("unpair", inner.Kind);
    }

    [Fact]
    public void MultiplePhonesHaveIndependentKeys()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var a = PairPhone(store, w, "A");
        var b = PairPhone(store, w, "B");
        Assert.NotEqual(a.Key, b.Key);
        Online(store, w, a);
        Online(store, w, b);
    }

    [Fact]
    public void SettingsMergeIsLastWriterWins()
    {
        var local = new SharedSettings(false, true, true, 100);
        Assert.Equal(new SharedSettings(true, false, false, 200), local.Merged(new SharedSettings(true, false, false, 200)));
        Assert.Equal(local, local.Merged(new SharedSettings(true, false, false, 50)));
    }

    [Fact]
    public void FilterAndDeduper()
    {
        var f = new SyncFilter();
        Assert.Equal("疑似敏感内容", f.Decide("com.sms", "短信", "您的验证码是 123456"));
        Assert.Null(f.Decide("com.sms", "张三", "晚上吃饭"));
        var d = new NotificationDeduper();
        Assert.Equal(NotificationDeduper.Result.New, d.Check("1", "t", "x"));
        Assert.Equal(NotificationDeduper.Result.Duplicate, d.Check("1", "t", "x"));
        Assert.Equal(NotificationDeduper.Result.Updated, d.Check("1", "t", "y"));
    }

    [Fact]
    public void ManyDevicesHighRateThroughStateMachines()
    {
        var store = new MemoryStore();
        var w = new PairingWindow();
        var list = Enumerable.Range(0, 12).Select(i => { var p = PairPhone(store, w, $"D{i}"); return (p, Online(store, w, p)); }).ToList();
        for (var round = 0; round < 300; round++)
        {
            foreach (var (p, m) in list)
            {
                var n = Assert.IsType<SessionOutput.Notify>(m.Handle(p.Notify($"n{round}")).First());
                Assert.Equal(round + 1, n.Seq);
                Assert.NotNull(p.Receive(Envelope.Parse(m.Ack(n.Seq, "shown")!)!));
            }
        }
    }
}
