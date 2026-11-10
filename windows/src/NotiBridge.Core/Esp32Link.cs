using System.Globalization;
using System.Text;
using System.Text.Json;

namespace NotiBridge.Core;

/// <summary>ESP32 固件串口协议（docs/esp32-serial.md）的事件。与 Mac 端 Esp32Link.swift 一致。</summary>
public abstract record Esp32Event
{
    public sealed record Hello(string Version, string BleAddress, int Proto) : Esp32Event;
    public sealed record State(Esp32LinkState Link) : Esp32Event;
    public sealed record Notification(IphoneNotification Item) : Esp32Event;
    public sealed record Removed(uint Uid) : Esp32Event;
    public sealed record Acted(uint Uid, int Action) : Esp32Event;
    public sealed record Error(string Code, string Message) : Esp32Event;
}

public sealed record Esp32LinkState(string Ble, string Peer, int Bonds, bool Pairing)
{
    public bool Ready => Ble == "ready";

    public string Label => Ble switch
    {
        "ready" => "iPhone 已连接",
        "encrypted" or "connected" => "iPhone 正在连接…",
        "advertising" => Bonds > 0 ? "等待 iPhone 连接" : "等待 iPhone 配对",
        _ => "蓝牙未就绪",
    };
}

public sealed record IphoneNotification(uint Uid, bool Modified, int Flags, int Category, string AppId, string AppName,
    string Title, string Subtitle, string Message, string Date, string PositiveLabel, string NegativeLabel)
{
    public const int FlagSilent = 1, FlagImportant = 2, FlagPreExisting = 4;

    /// <summary>连接时 iPhone 补发的已有通知（不弹出）</summary>
    public bool PreExisting => (Flags & FlagPreExisting) != 0;

    public DateTimeOffset? ParsedDate =>
        DateTime.TryParseExact(Date, "yyyyMMdd'T'HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var d)
            ? new DateTimeOffset(d) : null;

    public MirroredNotification Mirrored(DateTimeOffset? now = null)
    {
        var text = Subtitle.Length == 0 ? Message : Message.Length == 0 ? Subtitle : $"{Subtitle}\n{Message}";
        return new MirroredNotification($"ios-{Uid}", AppId, AppName.Length == 0 ? AppId : AppName, Title, text,
            ParsedDate ?? now ?? DateTimeOffset.Now, false);
    }
}

public static class Esp32LinkParser
{
    public static Esp32Event? Parse(string raw)
    {
        var line = raw.Trim();
        if (line.StartsWith("HB-ESP32 ", StringComparison.Ordinal))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var kv = parts.Skip(2).Select(p => p.Split('=', 2)).Where(p => p.Length == 2).ToDictionary(p => p[0], p => p[1]);
            return new Esp32Event.Hello(parts.Length > 1 ? parts[1] : "?", kv.GetValueOrDefault("ble", ""),
                int.TryParse(kv.GetValueOrDefault("proto"), out var pr) ? pr : 0);
        }
        if (!line.StartsWith("@{", StringComparison.Ordinal)) return null;
        try
        {
            using var doc = JsonDocument.Parse(line[1..]);
            var o = doc.RootElement;
            string S(string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";
            int I(string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : 0;
            uint? U(string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetUInt32(out var n) ? n : null;
            return S("t") switch
            {
                "state" => new Esp32Event.State(new Esp32LinkState(S("ble"), S("peer"), I("bonds"),
                    o.TryGetProperty("pairing", out var p) && p.ValueKind == JsonValueKind.True)),
                "notif" => U("uid") is uint uid
                    ? new Esp32Event.Notification(new IphoneNotification(uid, S("ev") == "mod", I("flags"), I("cat"), S("app"),
                        S("appName"), S("title"), S("sub"), S("msg"), S("date"), S("pos"), S("neg")))
                    : null,
                "removed" => U("uid") is uint r ? new Esp32Event.Removed(r) : null,
                "acted" => U("uid") is uint a ? new Esp32Event.Acted(a, I("action")) : null,
                "err" => new Esp32Event.Error(S("code"), S("msg")),
                _ => null,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>把串口字节流切成行（固件按 \n 结尾）。</summary>
public sealed class LineSplitter
{
    private readonly List<byte> _buf = [];

    public List<string> Feed(ReadOnlySpan<byte> bytes)
    {
        var lines = new List<string>();
        foreach (var b in bytes)
        {
            if (b == 0x0A)
            {
                lines.Add(Encoding.UTF8.GetString(_buf.ToArray()));
                _buf.Clear();
            }
            else _buf.Add(b);
        }
        if (_buf.Count > 16384) _buf.Clear();
        return lines;
    }
}

/// <summary>电脑端提取验证码，规则与安卓 Filter.kt、Mac OtpExtractor 一致。</summary>
public static class OtpExtractor
{
    private static readonly string[] Keywords = ["验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "激活码", "otp", "code"];
    private static readonly string[] Finance = ["银行", "信用卡", "余额", "转账", "支付", "付款", "收款", "还款", "贷款", "bank", "payment"];
    private static readonly string[] FinanceAppHints = ["bank", "alipay", "wallet", "pay", "finance", "securities", "stock", "icbc", "ccb", "cmb", "abchina", "boc"];
    private static readonly System.Text.RegularExpressions.Regex Digits = new("(?<![0-9])([0-9]{4,8})(?![0-9])");

    public static string Extract(string title, string text)
    {
        var content = $"{title} {text}";
        var lower = content.ToLowerInvariant();
        var keyPos = new List<int>();
        foreach (var k in Keywords)
        {
            for (int i = lower.IndexOf(k, StringComparison.Ordinal); i >= 0; i = lower.IndexOf(k, i + k.Length, StringComparison.Ordinal))
                keyPos.Add(i);
        }
        if (keyPos.Count == 0) return "";
        var best = "";
        var bestDist = int.MaxValue;
        foreach (System.Text.RegularExpressions.Match m in Digits.Matches(content))
        {
            foreach (var k in keyPos)
            {
                var d = Math.Abs(m.Index - k);
                if (d <= 40 && d < bestDist)
                {
                    bestDist = d;
                    best = m.Groups[1].Value;
                }
            }
        }
        return best;
    }

    public static bool IsFinance(string bundle, string title, string text)
    {
        var hay = $"{title}\n{text}".ToLowerInvariant();
        var b = bundle.ToLowerInvariant();
        return Finance.Any(hay.Contains) || FinanceAppHints.Any(b.Contains);
    }
}
