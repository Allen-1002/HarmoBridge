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
    /// <summary>手机取消了与这台电脑的配对，密钥已从存储中删除。</summary>
    public sealed record Unpaired(string DeviceId) : SessionOutput;
    /// <summary>旧版（协议 v1）手机尝试连接，已回 upgrade_required。</summary>
    public sealed record PeerOutdated : SessionOutput;
    public sealed record Log(string Text) : SessionOutput;
}

/// <summary>
/// 单条 WebSocket 连接的协议状态机（协议 v2），与 Mac 端 SessionMachine.swift 行为一致。
/// 与网络层解耦：输入一帧文本，输出要执行的动作。非线程安全，由调用方串行调用。
/// </summary>
public sealed class SessionMachine(IPairedKeyStore store, PairingWindow window, string computerId, string computerName,
    string platform = "windows")
{
    /// <summary>会让电脑端对来源 IP 计一次失败（退避/封禁）的关闭原因。</summary>
    public static readonly IReadOnlySet<string> FailureReasons = new HashSet<string>
    {
        "bad_frame", "unexpected", "bad_pin", "bad_point", "bad_pair_req", "bad_hello", "auth_failed", "bad_msg", "replay",
    };

    private enum Phase { AwaitingFirst, PairingAwaitKey, PairingAwaitConfirm, AwaitingAuth, Authenticated, Closed }

    private Phase _phase = Phase.AwaitingFirst;
    // 配对
    private BridgeCrypto.PairingContext? _ctx;
    private string _pin = "";
    private byte[] _yb = [];
    private byte[] _ybPub = [];
    private BridgeCrypto.PairingKeys? _keys;
    private string _name = "";
    // 会话
    private byte[]? _key;
    private string _phoneNonce = "";
    private string _sid = "";
    private int _lastSeq;
    private int _outSeq;

    /// <summary>测试用：固定电脑端 CPace 标量和 nonce。</summary>
    internal byte[]? FixedScalar { get; set; }
    internal byte[]? FixedNonce { get; set; }

    public string? DeviceId { get; private set; }
    public bool IsAuthenticated => _phase == Phase.Authenticated;
    /// <summary>配对进行中（已收到合法的 pair_req）：服务端据此放宽超时。</summary>
    public bool IsPairing => _phase is Phase.PairingAwaitKey or Phase.PairingAwaitConfirm;

    public IReadOnlyList<SessionOutput> Handle(string text, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        var env = Envelope.Parse(text);
        if (env is null) return Fail("bad_frame", "收到无法解析的帧");
        switch (_phase)
        {
            case Phase.AwaitingFirst:
                if (env.T is "pair_req" or "hello")
                {
                    if (env.V != BridgeCrypto.ProtocolVersion)
                    {
                        _phase = Phase.Closed;
                        return [new SessionOutput.Log("旧版手机（协议 v1）尝试连接，请把手机更新到 1.1.0"),
                            new SessionOutput.PeerOutdated(),
                            new SessionOutput.Send(new Envelope { T = "error", Code = "upgrade_required" }.ToJson()),
                            new SessionOutput.Close("upgrade_required")];
                    }
                    return env.T == "pair_req" ? StartPairing(env, t) : StartAuth(env);
                }
                return env.T == "info" ? Info() : Fail("unexpected", $"首帧类型非法：{env.T}");
            case Phase.PairingAwaitKey:
            {
                byte[]? ya = null;
                try { if (env.T == "pair_key" && env.Pub is not null) ya = Convert.FromBase64String(env.Pub); }
                catch (FormatException) { }
                if (ya is not { Length: 32 }) return Fail("unexpected", $"配对阶段收到非法帧：{env.T}");
                byte[] k;
                try { k = Cpace.ScalarMultVfy(_yb, ya); }
                catch (System.Security.Cryptography.CryptographicException)
                {
                    window.RecordFailure();
                    return Fail("bad_point", "配对失败：手机发来的公钥无效（低阶点）");
                }
                _keys = BridgeCrypto.DerivePairingKeys(k, _ctx!, ya, _ybPub);
                _phase = Phase.PairingAwaitConfirm;
                return [new SessionOutput.PairingStarted(_keys.Sas)];
            }
            case Phase.PairingAwaitConfirm:
            {
                byte[]? mac = null;
                try { if (env.T == "pair_confirm" && env.Confirm is not null) mac = Convert.FromBase64String(env.Confirm); }
                catch (FormatException) { }
                if (mac is null) return Fail("unexpected", $"配对阶段收到非法帧：{env.T}");
                // PIN 必须仍是发出 pair_chal 时的那一个（期间失败 3 次或过期都会作废）
                if (window.ActivePin(t) != _pin) return Fail("pairing_closed", "配对窗口已关闭或 PIN 已过期");
                if (!BridgeCrypto.ConstantTimeEqual(mac, _keys!.ConfirmPhone))
                {
                    window.RecordFailure();
                    return Fail("bad_pin", $"配对失败：PIN 错误或确认码无效（第 {window.Failures} 次）");
                }
                store.Save(DeviceId!, _name, _keys.PairKey);
                window.Close();
                _phase = Phase.Closed;
                var ok = new Envelope { T = "pair_ok", Confirm = Convert.ToBase64String(_keys.ConfirmComputer) };
                return [new SessionOutput.Send(ok.ToJson()), new SessionOutput.Paired(DeviceId!, _name, _keys.Sas),
                    new SessionOutput.Close("paired")];
            }
            case Phase.AwaitingAuth:
            {
                if (env.T != "auth" || !BridgeCrypto.TryOpen(_key!, env.Box, BridgeCrypto.Direction.ToComputer, out var plain) ||
                    plain != $"auth|{_phoneNonce}|{_sid}")
                    return Fail("auth_failed", $"认证失败：设备 {DeviceId}");
                _phase = Phase.Authenticated;
                _lastSeq = 0;
                var ok = new Envelope
                {
                    T = "auth_ok", Box = BridgeCrypto.Seal(_key!, $"ok|{_sid}|{_phoneNonce}", BridgeCrypto.Direction.ToPhone),
                };
                return [new SessionOutput.Send(ok.ToJson()), new SessionOutput.Authenticated(DeviceId!)];
            }
            case Phase.Authenticated:
            {
                if (env.T != "msg" || !BridgeCrypto.TryOpen(_key!, env.Box, BridgeCrypto.Direction.ToComputer, out var plain) ||
                    Inner.Parse(plain) is not { } inner)
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

    /// <summary>给手机回 ack（认证后才有效）。seq 为被确认的手机消息序号。</summary>
    public string? Ack(int seq, string result) => Frame(c => new Inner { Kind = "ack", Sid = _sid, Seq = seq, Cseq = c, Result = result });

    /// <summary>把电脑当前的设置发给手机。seq 为 null 时表示电脑主动推送。</summary>
    public string? SettingsFrame(SharedSettings st, int? seq = null) =>
        Frame(c => new Inner
        {
            Kind = "settings", Sid = _sid, Seq = seq ?? c, Cseq = c, Paused = st.Paused, BlockSensitive = st.BlockSensitive,
            CopyOtp = st.CopyOtp, UpdatedAt = st.UpdatedAt,
        });

    /// <summary>电脑上取消配对时通知在线的手机（认证后才有效），发出后由调用方断开。</summary>
    public string? UnpairFrame() => Frame(c => new Inner { Kind = "unpair", Sid = _sid, Seq = c, Cseq = c });

    /// <summary>电脑发给手机的每一条消息都带递增的 cseq（手机据此防重放）。</summary>
    private string? Frame(Func<int, Inner> build)
    {
        if (_phase != Phase.Authenticated || _key is null) return null;
        var inner = build(++_outSeq);
        return new Envelope { T = "msg", Box = BridgeCrypto.Seal(_key, inner.ToJson(), BridgeCrypto.Direction.ToPhone) }.ToJson();
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

    private static byte[]? B64(string? s, int len)
    {
        if (s is null) return null;
        try { var b = Convert.FromBase64String(s); return b.Length == len ? b : null; }
        catch (FormatException) { return null; }
    }

    private IReadOnlyList<SessionOutput> StartPairing(Envelope env, DateTimeOffset now)
    {
        var pin = window.ActivePin(now);
        if (pin is null) return Fail("pairing_closed", "收到配对请求，但电脑未开启配对");
        var phoneNonce = B64(env.Nonce, 16);
        if (string.IsNullOrEmpty(env.DeviceId) || System.Text.Encoding.UTF8.GetByteCount(env.DeviceId) > 128 || phoneNonce is null)
            return Fail("bad_pair_req", "配对请求字段不完整");
        var wireName = env.DeviceName ?? "";
        if (wireName.Length > 64) return Fail("bad_pair_req", "手机名称过长");
        var macNonce = FixedNonce ?? BridgeCrypto.RandomBytes(16);
        _ctx = new BridgeCrypto.PairingContext(env.DeviceId, wireName, env.Platform ?? "", computerId, computerName, platform,
            phoneNonce, macNonce);
        _pin = pin;
        _yb = FixedScalar ?? BridgeCrypto.RandomBytes(32);
        _ybPub = Cpace.ScalarMultVfy(_yb, _ctx.Generator(pin));
        _name = wireName.Length == 0 ? "未知设备" : wireName;
        DeviceId = env.DeviceId;
        _phase = Phase.PairingAwaitKey;
        var chal = new Envelope
        {
            T = "pair_chal", V = BridgeCrypto.ProtocolVersion, MacId = computerId, MacName = computerName, Platform = platform,
            Nonce = Convert.ToBase64String(macNonce), Pub = Convert.ToBase64String(_ybPub),
        };
        return [new SessionOutput.Send(chal.ToJson())];
    }

    private IReadOnlyList<SessionOutput> StartAuth(Envelope env)
    {
        if (env.DeviceId is null || B64(env.Nonce, 16) is null) return Fail("bad_hello", "hello 字段不完整");
        var key = store.KeyFor(env.DeviceId);
        if (key is null)
        {
            _phase = Phase.Closed;
            return [new SessionOutput.Log($"未配对设备尝试连接：{env.DeviceId}"),
                new SessionOutput.Send(new Envelope { T = "error", Code = "unknown_device" }.ToJson()),
                new SessionOutput.Close("unknown_device")];
        }
        _key = key;
        _phoneNonce = env.Nonce!;
        _sid = Convert.ToBase64String(FixedNonce ?? BridgeCrypto.RandomBytes(16));
        DeviceId = env.DeviceId;
        _phase = Phase.AwaitingAuth;
        return [new SessionOutput.Send(new Envelope { T = "challenge", V = BridgeCrypto.ProtocolVersion, Nonce = _sid }.ToJson())];
    }

    private IReadOnlyList<SessionOutput> Info()
    {
        _phase = Phase.Closed;
        var info = new Envelope
        {
            T = "info", V = BridgeCrypto.ProtocolVersion, MacId = computerId, MacName = computerName, Platform = platform,
        };
        return [new SessionOutput.Send(info.ToJson()), new SessionOutput.Close("info")];
    }

    private IReadOnlyList<SessionOutput> Fail(string code, string log)
    {
        _phase = Phase.Closed;
        return [new SessionOutput.Log(log), new SessionOutput.Send(new Envelope { T = "error", Code = code }.ToJson()),
            new SessionOutput.Close(code)];
    }
}
