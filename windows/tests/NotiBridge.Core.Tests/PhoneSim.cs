using NotiBridge.Core;

namespace NotiBridge.Core.Tests;

/// <summary>按协议 v2 模拟手机端（测试用，不是真机）。</summary>
public sealed class PhoneSim(string deviceId, string name = "Phone", string platform = "android")
{
    public string DeviceId { get; } = deviceId;
    public byte[]? Key { get; set; }
    public byte[] PhoneNonce { get; private set; } = [];
    public BridgeCrypto.PairingKeys? Keys { get; private set; }
    public string AuthNonce { get; private set; } = "";
    public string Sid { get; set; } = "";
    public int Seq { get; set; }
    public int LastCseq { get; private set; }

    public string PairReq(int? version = 2)
    {
        PhoneNonce = BridgeCrypto.RandomBytes(16);
        return new Envelope
        {
            T = "pair_req", V = version, DeviceId = DeviceId, DeviceName = name, Platform = platform,
            Nonce = Convert.ToBase64String(PhoneNonce),
        }.ToJson();
    }

    /// <summary>收到 pair_chal 后：按 PIN 算 g、Ya、K，返回 pair_key 帧。</summary>
    public string PairKey(Envelope chal, string pin)
    {
        var ctx = new BridgeCrypto.PairingContext(DeviceId, name, platform, chal.MacId ?? "", chal.MacName ?? "",
            chal.Platform ?? "", PhoneNonce, Convert.FromBase64String(chal.Nonce ?? ""));
        var ya = BridgeCrypto.RandomBytes(32);
        var yaPub = Cpace.ScalarMultVfy(ya, ctx.Generator(pin));
        var yb = Convert.FromBase64String(chal.Pub ?? "");
        Keys = BridgeCrypto.DerivePairingKeys(Cpace.ScalarMultVfy(ya, yb), ctx, yaPub, yb);
        return new Envelope { T = "pair_key", Pub = Convert.ToBase64String(yaPub) }.ToJson();
    }

    public string PairConfirm() => new Envelope { T = "pair_confirm", Confirm = Convert.ToBase64String(Keys!.ConfirmPhone) }.ToJson();

    /// <summary>核对电脑的确认码，通过才“保存”密钥。</summary>
    public bool AcceptPairOk(Envelope env)
    {
        if (env.T != "pair_ok" || env.Confirm is null || Keys is null) return false;
        if (!BridgeCrypto.ConstantTimeEqual(Convert.FromBase64String(env.Confirm), Keys.ConfirmComputer)) return false;
        Key = Keys.PairKey;
        return true;
    }

    public string Hello(int? version = 2)
    {
        AuthNonce = Convert.ToBase64String(BridgeCrypto.RandomBytes(16));
        return new Envelope { T = "hello", V = version, DeviceId = DeviceId, Nonce = AuthNonce }.ToJson();
    }

    public string Auth(Envelope challenge)
    {
        Sid = challenge.Nonce!;
        Seq = 0;
        LastCseq = 0;
        return new Envelope { T = "auth", Box = BridgeCrypto.Seal(Key!, $"auth|{AuthNonce}|{Sid}", BridgeCrypto.Direction.ToComputer) }.ToJson();
    }

    public bool CheckAuthOk(Envelope env) =>
        env.T == "auth_ok" && BridgeCrypto.TryOpen(Key!, env.Box, BridgeCrypto.Direction.ToPhone, out var p) && p == $"ok|{Sid}|{AuthNonce}";

    public string Msg(Inner inner) =>
        new Envelope { T = "msg", Box = BridgeCrypto.Seal(Key!, inner.ToJson(), BridgeCrypto.Direction.ToComputer) }.ToJson();

    public string Notify(string id, string title = "t", string text = "x") =>
        Msg(new Inner { Kind = "notify", Sid = Sid, Seq = ++Seq, Id = id, BundleName = "com.a", AppName = "A", Title = title, Text = text, Time = 1_700_000_000_000, Test = false });

    /// <summary>手机端对电脑消息的校验：sid 一致、cseq 严格递增；不通过返回 null。</summary>
    public Inner? Receive(Envelope env)
    {
        if (env.T != "msg" || !BridgeCrypto.TryOpen(Key!, env.Box, BridgeCrypto.Direction.ToPhone, out var plain)) return null;
        if (Inner.Parse(plain) is not { } inner || inner.Sid != Sid || inner.Cseq is not { } c || c <= LastCseq) return null;
        LastCseq = c;
        return inner;
    }
}

public sealed class MemoryStore : IPairedKeyStore
{
    private readonly object _gate = new();
    public Dictionary<string, byte[]> Keys { get; } = [];
    public byte[]? KeyFor(string deviceId) { lock (_gate) return Keys.GetValueOrDefault(deviceId); }
    public void Save(string deviceId, string name, byte[] key) { lock (_gate) Keys[deviceId] = key; }
    public void Remove(string deviceId) { lock (_gate) Keys.Remove(deviceId); }
}
