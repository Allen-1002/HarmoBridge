namespace NotiBridge.Core;

/// <summary>应用白名单 / 黑名单 + 敏感内容过滤。默认拦截验证码、银行、支付类通知。与 Mac 端 SyncFilter 一致。</summary>
public sealed class SyncFilter
{
    public enum FilterMode { AllExceptBlacklist, WhitelistOnly }

    public FilterMode Mode { get; set; } = FilterMode.AllExceptBlacklist;
    public HashSet<string> Whitelist { get; set; } = [];
    public HashSet<string> Blacklist { get; set; } = [];
    public bool BlockSensitive { get; set; } = true;
    public List<string> SensitiveKeywords { get; set; } = [.. DefaultKeywords];

    public static readonly string[] DefaultKeywords =
    [
        "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "OTP", "verification code",
        "银行", "信用卡", "余额", "转账", "支付", "付款", "收款",
    ];

    /// <summary>返回 null 表示放行，否则为拦截原因。</summary>
    public string? Decide(string bundleName, string title, string text)
    {
        if (Blacklist.Contains(bundleName)) return "黑名单应用";
        if (Mode == FilterMode.WhitelistOnly && !Whitelist.Contains(bundleName)) return "不在白名单";
        if (BlockSensitive)
        {
            var haystack = (title + "\n" + text).ToLowerInvariant();
            foreach (var k in SensitiveKeywords)
            {
                if (k.Length > 0 && haystack.Contains(k.ToLowerInvariant())) return "疑似敏感内容";
            }
        }
        return null;
    }
}

/// <summary>以通知 id 去重：同 id 同内容视为重复，同 id 新内容视为更新。线程安全。</summary>
public sealed class NotificationDeduper(TimeSpan? ttl = null, int capacity = 1000)
{
    public enum Result { New, Updated, Duplicate }

    private readonly Dictionary<string, (int Fingerprint, DateTimeOffset At)> _seen = [];
    private readonly TimeSpan _ttl = ttl ?? TimeSpan.FromHours(24);
    private readonly object _gate = new();

    public Result Check(string key, string title, string text, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        var fp = HashCode.Combine(title, text);
        lock (_gate)
        {
            Prune(t);
            var had = _seen.TryGetValue(key, out var old);
            _seen[key] = (fp, t);
            if (!had) return Result.New;
            return old.Fingerprint == fp ? Result.Duplicate : Result.Updated;
        }
    }

    public void Remove(string key)
    {
        lock (_gate) _seen.Remove(key);
    }

    private void Prune(DateTimeOffset now)
    {
        foreach (var k in _seen.Where(kv => now - kv.Value.At >= _ttl).Select(kv => kv.Key).ToList()) _seen.Remove(k);
        if (_seen.Count > capacity)
        {
            foreach (var k in _seen.OrderBy(kv => kv.Value.At).Take(_seen.Count - capacity).Select(kv => kv.Key).ToList())
                _seen.Remove(k);
        }
    }
}
