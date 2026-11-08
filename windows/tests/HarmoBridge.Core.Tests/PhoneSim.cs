using HarmoBridge.Core;

namespace HarmoBridge.Core.Tests;

/// <summary>按协议模拟手机端（测试用，不是真机）。</summary>
public sealed class PhoneSim(string deviceId, string name = "Phone")
{
    public string DeviceId { get; } = deviceId;
    public byte[]? Key { get; set; }
    public string PhoneNonce { get; private set; } = "";
    public string Sid { get; set; } = "";
    public int Seq { get; set; }
    private BridgeCrypto.X25519KeyPair? _priv;

    public string PairReq()
    {
        _priv = BridgeCrypto.X25519KeyPair.Generate();
        return new Envelope { T = "pair_req", DeviceId = DeviceId, DeviceName = name, Pub = Convert.ToBase64String(_priv.PublicRaw) }.ToJson();
    }

    public string PairConfirm(Envelope chal, string pin)
    {
        var macPub = Convert.FromBase64String(chal.Pub!);
        Key = BridgeCrypto.DerivePairKey(_priv!, macPub, _priv!.PublicRaw, macPub, pin);
        return new Envelope { T = "pair_confirm", Box = BridgeCrypto.Seal(Key, "pair-confirm-phone") }.ToJson();
    }

    public string Hello()
    {
        PhoneNonce = Convert.ToBase64String(BridgeCrypto.RandomBytes(16));
        return new Envelope { T = "hello", DeviceId = DeviceId, Nonce = PhoneNonce }.ToJson();
    }

    public string Auth(Envelope challenge)
    {
        Sid = challenge.Nonce!;
        Seq = 0;
        return new Envelope { T = "auth", Box = BridgeCrypto.Seal(Key!, $"auth|{PhoneNonce}|{Sid}") }.ToJson();
    }

    public string Msg(Inner inner) => new Envelope { T = "msg", Box = BridgeCrypto.Seal(Key!, inner.ToJson()) }.ToJson();

    public string Notify(string id, string title = "t", string text = "x") =>
        Msg(new Inner { Kind = "notify", Sid = Sid, Seq = ++Seq, Id = id, BundleName = "com.a", AppName = "A", Title = title, Text = text, Time = 1_700_000_000_000, Test = false });

    public Inner OpenInner(Envelope env) => Inner.Parse(BridgeCrypto.Open(Key!, env.Box!))!;
}

public sealed class MemoryStore : IPairedKeyStore
{
    public Dictionary<string, byte[]> Keys { get; } = [];
    public byte[]? KeyFor(string deviceId) => Keys.GetValueOrDefault(deviceId);
    public void Save(string deviceId, string name, byte[] key) => Keys[deviceId] = key;
}
