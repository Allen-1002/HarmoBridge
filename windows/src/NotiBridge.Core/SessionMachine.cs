namespace NotiBridge.Core;

/// <summary>已配对手机的密钥存储（App 中用 DPAPI 加密文件实现，测试中用内存实现）。</summary>
public interface IPairedKeyStore
{
    byte[]? KeyFor(string deviceId);
    void Save(string deviceId, string name, byte[] key);
    /// <summary>v1.2：手机通过 unpair 消息取消配对时删除该手机的密钥。</summary>
    void Remove(string deviceId);
}

/// <summary>电脑端当前开放的配对窗口：一次性 PIN，限时、限次。线程安全。</summary>
public sealed class PairingWindow(TimeSpan? lifetime = null)
{
    public const int MaxFailures = 3;
    private readonly TimeSpan _lifetime = lifetime ?? TimeSpan.FromMinutes(2);
    private readonly object _gate = new();
    private string? _pin;
    private DateTimeOffset _expiresAt;

    public int Failures { get; private set; }

    public void Open(DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            _pin = BridgeCrypto.RandomPin();
            _expiresAt = (now ?? DateTimeOffset.UtcNow) + _lifetime;
            Failures = 0;
        }
    }

    public void Close()
    {
        lock (_gate) _pin = null;
    }

    public string? ActivePin(DateTimeOffset? now = null)
    {
        lock (_gate) return _pin is not null && (now ?? DateTimeOffset.UtcNow) < _expiresAt ? _pin : null;
    }

    public DateTimeOffset? ExpiresAt
    {
        get { lock (_gate) return _pin is null ? null : _expiresAt; }
    }

    /// <summary>PIN 错误一次；达到上限时作废。</summary>
    public void RecordFailure()
    {
        lock (_gate)
        {
            Failures++;
            if (Failures >= MaxFailures) _pin = null;
        }
    }
}

/// <summary>状态机输出的动作。</summary>
public abstract record SessionOutput
{
    public sealed record Send(string Frame) : SessionOutput;
    public sealed record Close(string Reason) : SessionOutput;
    public sealed record Paired(string DeviceId, string Name, string Sas) : SessionOutput;
    public sealed record PairingStarted(string Sas) : SessionOutput;
    public sealed record Authenticated(string DeviceId) : SessionOutput;
    public sealed record Notify(MirroredNotification Notification, int Seq) : SessionOutput;
    public sealed record Cancel(string[] Ids, int Seq) : SessionOutput;
    public sealed record Otp(OtpCode Code, int Seq) : SessionOutput;
    public sealed record Settings(SharedSettings Value, int Seq) : SessionOutput;
    public sealed record Ping(int Seq) : SessionOutput;
    /// <summary>v1.2：手机取消了与这台电脑的配对，密钥已从存储中删除。</summary>
    public sealed record Unpaired(string DeviceId) : SessionOutput;
    public sealed record Log(string Text) : SessionOutput;
}

/// <summary>
/// 单条 WebSocket 连接的协议状态机，与 Mac 端 SessionMachine.swift 行为一致。
/// 与网络层解耦：输入一帧文本，输出要执行的动作。非线程安全，由调用方串行调用。
/// </summary>
public sealed class SessionMachine(IPairedKeyStore store, PairingWindow window, string computerId, string computerName,
    string platform = "windows")
{
    private enum Phase { AwaitingFirst, Pairing, AwaitingAuth, Authenticated, Closed }

    private Phase _phase = Phase.AwaitingFirst;
    // 配对
    private BridgeCrypto.X25519KeyPair? _priv;
    private byte[] _phonePub = [];
    private byte[] _macPub = [];
    private string _name = "";
    private string _sas = "";
    // 会话
    private byte[]? _key;
    private string _phoneNonce = "";
    private string _sid = "";
    private int _lastSeq;
    private int _outSeq;

    public string? DeviceId { get; private set; }
    public bool IsAuthenticated => _phase == Phase.Authenticated;

    public IReadOnlyList<SessionOutput> Handle(string text, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        var env = Envelope.Parse(text);
        if (env is null) return Fail("bad_frame", "收到无法解析的帧");
        switch (_phase)
        {
            case Phase.AwaitingFirst:
                return env.T switch
                {
                    "pair_req" => StartPairing(env, t),
                    "hello" => StartAuth(env),
                    "info" => Info(),
                    _ => Fail("unexpected", $"首帧类型非法：{env.T}"),
                };
            case Phase.Pairing:
            {
                if (env.T != "pair_confirm" || env.Box is null) return Fail("unexpected", $"配对阶段收到非法帧：{env.T}");
                var pin = window.ActivePin(t);
                if (pin is null) return Fail("pairing_closed", "配对窗口已关闭或 PIN 已过期");
                byte[] key;
                try { key = BridgeCrypto.DerivePairKey(_priv!, _phonePub, _phonePub, _macPub, pin); }
                catch (System.Security.Cryptography.CryptographicException) { return Fail("bad_pair_req", "手机公钥无效"); }
                if (!BridgeCrypto.TryOpen(key, env.Box, out var plain) || plain != "pair-confirm-phone")
                {
                    window.RecordFailure();
                    return Fail("bad_pin", $"配对失败：PIN 错误（第 {window.Failures} 次）");
                }
                store.Save(DeviceId!, _name, key);
                window.Close();
                _phase = Phase.Closed;
                var ok = new Envelope { T = "pair_ok", Box = BridgeCrypto.Seal(key, "pair-confirm-mac") };
                return [new SessionOutput.Send(ok.ToJson()), new SessionOutput.Paired(DeviceId!, _name, _sas),
                    new SessionOutput.Close("paired")];
            }
            case Phase.AwaitingAuth:
            {
                if (env.T != "auth" || !BridgeCrypto.TryOpen(_key!, env.Box, out var plain) ||
                    plain != $"auth|{_phoneNonce}|{_sid}")
                    return Fail("auth_failed", $"认证失败：设备 {DeviceId}");
                _phase = Phase.Authenticated;
                _lastSeq = 0;
                var ok = new Envelope { T = "auth_ok", Box = BridgeCrypto.Seal(_key!, $"ok|{_sid}|{_phoneNonce}") };
                return [new SessionOutput.Send(ok.ToJson()), new SessionOutput.Authenticated(DeviceId!)];
            }
            case Phase.Authenticated:
            {
                if (env.T != "msg" || !BridgeCrypto.TryOpen(_key!, env.Box, out var plain) || Inner.Parse(plain) is not { } inner)
                    return Fail("bad_msg", "无法解密的业务消息");
                if (inner.Sid != _sid || inner.Seq <= _lastSeq)
                    return Fail("replay", $"拒绝重放或乱序消息 seq={inner.Seq}");
                _lastSeq = inner.Seq;
                return Dispatch(inner, t);
            }
            default:
                return [];
        }
    }

    /// <summary>给手机回 ack（认证后才有效）。</summary>
    public string? Ack(int seq, string result) =>
        Frame(new Inner { Kind = "ack", Sid = _sid, Seq = seq, Result = result });

    /// <summary>把电脑当前的设置发给手机。seq 为 null 时表示电脑主动推送（使用电脑自己的递增序号）。</summary>
    public string? SettingsFrame(SharedSettings st, int? seq = null) =>
        Frame(new Inner
        {
            Kind = "settings", Sid = _sid, Seq = seq ?? ++_outSeq, Paused = st.Paused, BlockSensitive = st.BlockSensitive,
            CopyOtp = st.CopyOtp, UpdatedAt = st.UpdatedAt,
        });

    /// <summary>v1.2：电脑上取消配对时通知在线的手机（认证后才有效），发出后由调用方断开。</summary>
    public string? UnpairFrame() =>
        _phase == Phase.Authenticated ? Frame(new Inner { Kind = "unpair", Sid = _sid, Seq = ++_outSeq }) : null;

    private string? Frame(Inner inner)
    {
        if (_phase != Phase.Authenticated || _key is null) return null;
        return new Envelope { T = "msg", Box = BridgeCrypto.Seal(_key, inner.ToJson()) }.ToJson();
    }

    private IReadOnlyList<SessionOutput> Dispatch(Inner inner, DateTimeOffset now)
    {
        switch (inner.Kind)
        {
            case "notify":
                if (string.IsNullOrEmpty(inner.Id)) return [new SessionOutput.Log("notify 缺少 id，已忽略")];
                var bundle = inner.BundleName ?? "";
                var n = new MirroredNotification(inner.Id, bundle, inner.AppName ?? bundle, inner.Title ?? "",
                    inner.Text ?? "",
                    inner.Time is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms) : now, inner.Test ?? false);
                return [new SessionOutput.Notify(n, inner.Seq)];
            case "cancel":
                return [new SessionOutput.Cancel(inner.Ids ?? [], inner.Seq)];
            case "settings":
                if (inner.UpdatedAt is not { } ts) return [new SessionOutput.Log("设置消息缺少修改时间，已忽略")];
                return [new SessionOutput.Settings(new SharedSettings(inner.Paused ?? false, inner.BlockSensitive ?? true,
                    inner.CopyOtp ?? true, ts), inner.Seq)];
            case "otp":
                var code = inner.Code;
                if (code is null || code.Length < 4 || code.Length > 8 || !code.All(char.IsAsciiDigit))
                    return [new SessionOutput.Log("验证码消息格式不对，已忽略")];
                var b = inner.BundleName ?? "";
                return [new SessionOutput.Otp(new OtpCode(inner.Id ?? "", b, inner.AppName ?? b, code), inner.Seq)];
            case "ping":
                return [new SessionOutput.Ping(inner.Seq)];
            case "unpair":
            {
                // 手机删除了这台电脑：删除密钥、回执、断开。之后这台手机再连接会收到 unknown_device。
                var ack = Ack(inner.Seq, "unpaired");
                var dev = DeviceId!;
                store.Remove(dev);
                _phase = Phase.Closed;
                var outs = new List<SessionOutput>
                {
                    new SessionOutput.Log($"手机已取消与这台电脑的配对：{dev}"), new SessionOutput.Unpaired(dev),
                };
                if (ack is not null) outs.Add(new SessionOutput.Send(ack));
                outs.Add(new SessionOutput.Close("unpaired"));
                return outs;
            }
            default:
                // call.* 预留给 ESP32 通话模块，通知模块不处理
                return [new SessionOutput.Log($"忽略未知消息类型：{inner.Kind}")];
        }
    }

    private IReadOnlyList<SessionOutput> StartPairing(Envelope env, DateTimeOffset now)
    {
        if (window.ActivePin(now) is null) return Fail("pairing_closed", "收到配对请求，但电脑未开启配对");
        byte[]? phonePub = null;
        try { if (env.Pub is not null) phonePub = Convert.FromBase64String(env.Pub); }
        catch (FormatException) { }
        if (string.IsNullOrEmpty(env.DeviceId) || phonePub is not { Length: 32 })
            return Fail("bad_pair_req", "配对请求字段不完整");
        _priv = BridgeCrypto.X25519KeyPair.Generate();
        _phonePub = phonePub;
        _macPub = _priv.PublicRaw;
        _sas = BridgeCrypto.Sas(_phonePub, _macPub);
        _name = string.IsNullOrEmpty(env.DeviceName) ? "未知设备" : env.DeviceName;
        DeviceId = env.DeviceId;
        _phase = Phase.Pairing;
        var chal = new Envelope
        {
            T = "pair_chal", MacId = computerId, MacName = computerName, Platform = platform,
            Pub = Convert.ToBase64String(_macPub),
        };
        return [new SessionOutput.Send(chal.ToJson()), new SessionOutput.PairingStarted(_sas)];
    }

    private IReadOnlyList<SessionOutput> StartAuth(Envelope env)
    {
        byte[]? raw = null;
        try { if (env.Nonce is not null) raw = Convert.FromBase64String(env.Nonce); }
        catch (FormatException) { }
        if (env.DeviceId is null || raw is not { Length: 16 }) return Fail("bad_hello", "hello 字段不完整");
        var key = store.KeyFor(env.DeviceId);
        if (key is null)
        {
            // v1.2：附带电脑 ID，手机据此确认是“这台电脑”不认识它（已在电脑上取消配对），再从列表中移除
            _phase = Phase.Closed;
            return [new SessionOutput.Log($"未配对设备尝试连接：{env.DeviceId}"),
                new SessionOutput.Send(new Envelope { T = "error", Code = "unknown_device", MacId = computerId }.ToJson()),
                new SessionOutput.Close("unknown_device")];
        }
        _key = key;
        _phoneNonce = env.Nonce!;
        _sid = Convert.ToBase64String(BridgeCrypto.RandomBytes(16));
        DeviceId = env.DeviceId;
        _phase = Phase.AwaitingAuth;
        return [new SessionOutput.Send(new Envelope { T = "challenge", Nonce = _sid }.ToJson())];
    }

    private IReadOnlyList<SessionOutput> Info()
    {
        _phase = Phase.Closed;
        var info = new Envelope { T = "info", MacId = computerId, MacName = computerName, Platform = platform };
        return [new SessionOutput.Send(info.ToJson()), new SessionOutput.Close("info")];
    }

    private IReadOnlyList<SessionOutput> Fail(string code, string log)
    {
        _phase = Phase.Closed;
        return [new SessionOutput.Log(log), new SessionOutput.Send(new Envelope { T = "error", Code = code }.ToJson()),
            new SessionOutput.Close(code)];
    }
}
