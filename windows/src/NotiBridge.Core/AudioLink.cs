using System.Text;

namespace NotiBridge.Core;

/// <summary>串口上混合的文本行和二进制音频帧，与 Mac 端 AudioLink.swift 一致。
/// 帧：0xFE 0xA5 类型(1) 长度(2, 小端) 序号(2, 小端) 数据；0xFE 不会出现在 UTF-8 文本里。</summary>
public enum SerialFrameType : byte { AudioDown = 0x01, AudioUp = 0x02 }

public sealed record SerialFrame(byte Type, ushort Seq, byte[] Data);

public sealed class SerialDemux
{
    public const int MaxFrame = 1024;
    private readonly List<byte> _line = [];
    private int _state; // 0 文本，1 收到 0xFE，2 帧头，3 数据
    private readonly byte[] _hdr = new byte[5];
    private int _hdrN;
    private byte[] _payload = [];
    private int _len, _got;

    /// <summary>喂入字节，回调输出文本行和帧</summary>
    public void Feed(ReadOnlySpan<byte> bytes, Action<string> onLine, Action<SerialFrame> onFrame)
    {
        foreach (var b in bytes)
        {
            switch (_state)
            {
                case 1:
                    _state = b == 0xA5 ? 2 : 0;
                    _hdrN = 0;
                    break;
                case 2:
                    _hdr[_hdrN++] = b;
                    if (_hdrN == 5)
                    {
                        _len = _hdr[1] | _hdr[2] << 8;
                        _got = 0;
                        if (_len == 0 || _len > MaxFrame) _state = 0;
                        else { _payload = new byte[_len]; _state = 3; }
                    }
                    break;
                case 3:
                    _payload[_got++] = b;
                    if (_got == _len)
                    {
                        onFrame(new SerialFrame(_hdr[0], (ushort)(_hdr[3] | _hdr[4] << 8), _payload));
                        _state = 0;
                    }
                    break;
                default:
                    if (b == 0xFE) _state = 1;
                    else if (b == 0x0A)
                    {
                        onLine(Encoding.UTF8.GetString(_line.ToArray()));
                        _line.Clear();
                    }
                    else
                    {
                        _line.Add(b);
                        if (_line.Count > 16384) _line.Clear();
                    }
                    break;
            }
        }
    }

    public static byte[] Encode(SerialFrameType type, ushort seq, ReadOnlySpan<byte> data)
    {
        var o = new byte[7 + data.Length];
        o[0] = 0xFE; o[1] = 0xA5; o[2] = (byte)type;
        o[3] = (byte)(data.Length & 0xFF); o[4] = (byte)(data.Length >> 8);
        o[5] = (byte)(seq & 0xFF); o[6] = (byte)(seq >> 8);
        data.CopyTo(o.AsSpan(7));
        return o;
    }
}

/// <summary>抖动缓冲，与 Mac 端一致：保持约 target 毫秒余量，积压过多丢弃，不够补静音并重新攒。</summary>
public sealed class JitterBuffer(int sampleRate, int targetMs = 60, int maxMs = 160)
{
    private readonly object _lock = new();
    private readonly Queue<short> _q = new();
    private readonly int _target = sampleRate * targetMs / 1000;
    private readonly int _high = sampleRate * maxMs / 1000;
    private bool _primed;
    public int SampleRate { get; } = sampleRate;
    public int Underruns { get; private set; }
    public int Dropped { get; private set; }

    public int Count { get { lock (_lock) return _q.Count; } }

    public void Push(ReadOnlySpan<short> s)
    {
        lock (_lock)
        {
            foreach (var v in s) _q.Enqueue(v);
            if (_q.Count > _high)
            {
                int drop = _q.Count - _target;
                for (int i = 0; i < drop; i++) _q.Dequeue();
                Dropped += drop;
            }
            if (!_primed && _q.Count >= _target) _primed = true;
        }
    }

    public void Pull(Span<short> dst)
    {
        lock (_lock)
        {
            if (!_primed) { dst.Clear(); return; }
            int i = 0;
            while (i < dst.Length && _q.Count > 0) dst[i++] = _q.Dequeue();
            if (i < dst.Length)
            {
                dst[i..].Clear();
                Underruns++;
                _primed = false;
            }
        }
    }

    public void Reset()
    {
        lock (_lock) { _q.Clear(); _primed = false; }
    }
}

public static class Pcm16
{
    public static short[] Samples(ReadOnlySpan<byte> b)
    {
        var o = new short[b.Length / 2];
        for (int i = 0; i < o.Length; i++) o[i] = (short)(b[2 * i] | b[2 * i + 1] << 8);
        return o;
    }

    public static byte[] Bytes(ReadOnlySpan<short> s)
    {
        var o = new byte[s.Length * 2];
        for (int i = 0; i < s.Length; i++) { o[2 * i] = (byte)s[i]; o[2 * i + 1] = (byte)(s[i] >> 8); }
        return o;
    }
}

/// <summary>电话号码归一化与通讯录索引，与 Mac 端 PhoneNumbers.swift 一致。</summary>
public static class PhoneNumbers
{
    public static string Digits(string s)
    {
        var d = new string(s.Where(char.IsAsciiDigit).ToArray());
        if (d.StartsWith("00", StringComparison.Ordinal)) d = d[2..];
        if (d.StartsWith("86", StringComparison.Ordinal) && d.Length == 13) d = d[2..];
        return d;
    }

    public static string Key(string s)
    {
        var d = Digits(s);
        return d.Length > 11 ? d[^11..] : d;
    }
}

public sealed record ContactEntry(string Name, string Number);

public sealed class ContactIndex
{
    private readonly List<ContactEntry> _entries = [];
    private readonly Dictionary<string, string> _byKey = [];

    public ContactIndex(IEnumerable<ContactEntry>? entries = null)
    {
        if (entries is not null) foreach (var e in entries) Add(e);
    }

    public IReadOnlyList<ContactEntry> Entries => _entries;

    public void Add(ContactEntry e)
    {
        var k = PhoneNumbers.Key(e.Number);
        if (k.Length == 0 || string.IsNullOrWhiteSpace(e.Name)) return;
        _entries.Add(e);
        _byKey.TryAdd(k, e.Name);
    }

    public string? NameFor(string number)
    {
        var k = PhoneNumbers.Key(number);
        return k.Length == 0 ? null : _byKey.GetValueOrDefault(k);
    }

    public List<ContactEntry> Search(string q, int limit = 8)
    {
        var t = q.Trim();
        if (t.Length == 0) return [];
        var d = PhoneNumbers.Digits(t);
        return _entries.Where(e => e.Name.Contains(t, StringComparison.OrdinalIgnoreCase)
                                   || (d.Length > 0 && PhoneNumbers.Digits(e.Number).Contains(d, StringComparison.Ordinal)))
            .Take(limit).ToList();
    }
}

/// <summary>导入手机导出的联系人：vCard（.vcf）或 CSV（第一列名字，其余列里的号码）。</summary>
public static class ContactImport
{
    public static List<ContactEntry> ParseVcf(string text)
    {
        var list = new List<ContactEntry>();
        // 折行：以空格或 Tab 开头的行接到上一行
        var lines = new List<string>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            if ((raw.StartsWith(' ') || raw.StartsWith('\t')) && lines.Count > 0) lines[^1] += raw[1..];
            else lines.Add(raw);
        }
        string name = "", n = "";
        var numbers = new List<string>();
        foreach (var l in lines)
        {
            var colon = l.IndexOf(':');
            if (colon < 0)
            {
                if (l.Equals("END:VCARD", StringComparison.OrdinalIgnoreCase)) { }
                continue;
            }
            var key = l[..colon];
            var val = l[(colon + 1)..].Trim();
            var prop = key.Split(';')[0].ToUpperInvariant();
            if (key.Contains("QUOTED-PRINTABLE", StringComparison.OrdinalIgnoreCase)) val = DecodeQp(val, key);
            switch (prop)
            {
                case "BEGIN": name = ""; n = ""; numbers.Clear(); break;
                case "FN": name = Unescape(val); break;
                case "N":
                    {
                        // N:姓;名;…  中文名“姓名”连写，西文名“名 姓”
                        var parts = Unescape(val).Split(';');
                        var family = parts.Length > 0 ? parts[0].Trim() : "";
                        var given = parts.Length > 1 ? parts[1].Trim() : "";
                        n = (family + given).Any(c => c >= 0x3400) ? family + given : $"{given} {family}".Trim();
                        break;
                    }
                case "TEL": if (val.Length > 0) numbers.Add(val); break;
                case "END":
                    var who = name.Length > 0 ? name : n;
                    foreach (var num in numbers) if (who.Length > 0) list.Add(new ContactEntry(who, num));
                    break;
            }
        }
        return list;
    }

    private static string Unescape(string s) => s.Replace("\\,", ",").Replace("\\;", ";").Replace("\\n", " ").Replace("\\\\", "\\");

    private static string DecodeQp(string s, string key)
    {
        var bytes = new List<byte>();
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '=' && i + 2 < s.Length && Uri.IsHexDigit(s[i + 1]) && Uri.IsHexDigit(s[i + 2]))
            {
                bytes.Add(Convert.ToByte(s.Substring(i + 1, 2), 16));
                i += 2;
            }
            else bytes.Add((byte)s[i]);
        }
        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    /// <summary>CSV：第一列是名字，其余列里像号码的都算（兼容带表头的导出文件）</summary>
    public static List<ContactEntry> ParseCsv(string text)
    {
        var list = new List<ContactEntry>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var cols = SplitCsv(raw);
            if (cols.Count < 2) continue;
            var name = cols[0].Trim();
            foreach (var c in cols.Skip(1))
            {
                var d = PhoneNumbers.Digits(c);
                if (d.Length >= 3 && d.Length <= 15 && c.Count(char.IsLetter) == 0) list.Add(new ContactEntry(name, c.Trim()));
            }
        }
        return list.Where(e => e.Name.Length > 0).ToList();
    }

    private static List<string> SplitCsv(string line)
    {
        var cols = new List<string>();
        var sb = new StringBuilder();
        bool q = false;
        for (int i = 0; i < line.Length; i++)
        {
            var ch = line[i];
            if (q)
            {
                if (ch == '"' && i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; }
                else if (ch == '"') q = false;
                else sb.Append(ch);
            }
            else if (ch == '"') q = true;
            else if (ch == ',') { cols.Add(sb.ToString()); sb.Clear(); }
            else sb.Append(ch);
        }
        cols.Add(sb.ToString());
        return cols;
    }
}
