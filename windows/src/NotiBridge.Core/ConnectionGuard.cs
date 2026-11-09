namespace NotiBridge.Core;

/// <summary>
/// 电脑端 WebSocket 服务的防滥用策略（与 Mac ConnectionGuard.swift 一致，见 docs/protocol.md “电脑端连接限制”）。
/// 纯逻辑，线程安全。
/// </summary>
public sealed class ConnectionGuard
{
    public sealed record Limits
    {
        public int MaxConnections { get; init; } = 16;
        public int MaxNewPerMinutePerIp { get; init; } = 10;
        public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(10);
        public TimeSpan PairingTimeout { get; init; } = TimeSpan.FromSeconds(90);
        public int MaxFrameBeforeAuth { get; init; } = 16 * 1024;
        public int MaxFrameAfterAuth { get; init; } = 256 * 1024;
        public int FailuresBeforeLockout { get; init; } = 3;
        public TimeSpan BaseLockout { get; init; } = TimeSpan.FromSeconds(30);
        public TimeSpan MaxLockout { get; init; } = TimeSpan.FromHours(1);
    }

    public enum Verdict { Allow, TooManyConnections, RateLimited, LockedOut }

    private sealed class IpState
    {
        public List<DateTimeOffset> Recent { get; } = [];
        public int Failures { get; set; }
        public DateTimeOffset? LockedUntil { get; set; }
    }

    private readonly object _gate = new();
    private readonly Dictionary<string, IpState> _ips = new(StringComparer.Ordinal);
    private int _open;

    public ConnectionGuard(Limits? limits = null) => Config = limits ?? new Limits();

    public Limits Config { get; }

    public int OpenConnections
    {
        get { lock (_gate) return _open; }
    }

    /// <summary>新连接到来时调用；返回 Allow 时已计入连接数，关闭时必须调用 ConnectionClosed()。</summary>
    public Verdict Admit(string ip, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        lock (_gate)
        {
            Prune(t);
            var st = Get(ip);
            if (st.LockedUntil is { } until && until > t) return Verdict.LockedOut;
            if (_open >= Config.MaxConnections) return Verdict.TooManyConnections;
            st.Recent.RemoveAll(x => t - x >= TimeSpan.FromMinutes(1));
            if (st.Recent.Count >= Config.MaxNewPerMinutePerIp) return Verdict.RateLimited;
            st.Recent.Add(t);
            _open++;
            return Verdict.Allow;
        }
    }

    public void ConnectionClosed()
    {
        lock (_gate) _open = Math.Max(0, _open - 1);
    }

    /// <summary>认证/配对失败：累计到阈值后封禁，之后每次失败封禁时间翻倍。</summary>
    public void RecordFailure(string ip, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        lock (_gate)
        {
            var st = Get(ip);
            st.Failures++;
            if (st.Failures >= Config.FailuresBeforeLockout)
            {
                var exp = st.Failures - Config.FailuresBeforeLockout;
                var secs = Math.Min(Config.MaxLockout.TotalSeconds, Config.BaseLockout.TotalSeconds * Math.Pow(2, exp));
                st.LockedUntil = t + TimeSpan.FromSeconds(secs);
            }
        }
    }

    public void RecordSuccess(string ip)
    {
        lock (_gate)
        {
            if (!_ips.TryGetValue(ip, out var st)) return;
            st.Failures = 0;
            st.LockedUntil = null;
        }
    }

    public DateTimeOffset? LockedUntil(string ip)
    {
        lock (_gate) return _ips.TryGetValue(ip, out var st) ? st.LockedUntil : null;
    }

    public int FailureCount(string ip)
    {
        lock (_gate) return _ips.TryGetValue(ip, out var st) ? st.Failures : 0;
    }

    public int MaxFrame(bool authenticated) => authenticated ? Config.MaxFrameAfterAuth : Config.MaxFrameBeforeAuth;

    public TimeSpan Deadline(bool isPairing) => isPairing ? Config.PairingTimeout : Config.HandshakeTimeout;

    private IpState Get(string ip)
    {
        if (!_ips.TryGetValue(ip, out var st)) _ips[ip] = st = new IpState();
        return st;
    }

    private void Prune(DateTimeOffset now)
    {
        if (_ips.Count < 1024) return;
        foreach (var k in _ips.Where(kv => !(kv.Value.LockedUntil > now) &&
                                           !kv.Value.Recent.Any(x => now - x < TimeSpan.FromHours(1)))
                     .Select(kv => kv.Key).ToList())
            _ips.Remove(k);
    }
}
