using System.Security.Cryptography;
using System.Text;

namespace NotiBridge.Core;

/// <summary>
/// ESP32 芯片内置 ROM 下载协议（esptool 用的同一套串口协议），在程序里直接刷写固件，不需要 Python/esptool。
/// 与 Mac 端 EspRom.swift 逻辑一致。
/// </summary>
public static class EspSlip
{
    public static byte[] Encode(ReadOnlySpan<byte> data)
    {
        var o = new List<byte>(data.Length + 8) { 0xC0 };
        foreach (var b in data)
        {
            if (b == 0xC0) { o.Add(0xDB); o.Add(0xDC); }
            else if (b == 0xDB) { o.Add(0xDB); o.Add(0xDD); }
            else o.Add(b);
        }
        o.Add(0xC0);
        return o.ToArray();
    }

    public sealed class Decoder
    {
        private readonly List<byte> _frame = [];
        private bool _inFrame, _escape;

        public List<byte[]> Feed(ReadOnlySpan<byte> bytes)
        {
            var frames = new List<byte[]>();
            foreach (var b in bytes)
            {
                if (b == 0xC0)
                {
                    if (_inFrame && _frame.Count > 0) frames.Add(_frame.ToArray());
                    _frame.Clear();
                    _inFrame = true;
                    _escape = false;
                    continue;
                }
                if (!_inFrame) continue;
                if (_escape)
                {
                    _escape = false;
                    _frame.Add(b == 0xDC ? (byte)0xC0 : b == 0xDD ? (byte)0xDB : b);
                }
                else if (b == 0xDB) _escape = true;
                else _frame.Add(b);
            }
            return frames;
        }
    }
}

public enum EspRomCommand : byte
{
    FlashBegin = 0x02,
    FlashData = 0x03,
    FlashEnd = 0x04,
    Sync = 0x08,
    SpiSetParams = 0x0B,
    SpiAttach = 0x0D,
    ChangeBaudrate = 0x0F,
    SpiFlashMd5 = 0x13,
}

public sealed record EspRomResponse(byte Command, uint Value, byte[] Data)
{
    /// <summary>ESP32 ROM 的响应数据末尾是 4 字节状态：第 1 字节 0 为成功，第 2 字节是错误码。</summary>
    public bool Ok => Data.Length >= 4 && Data[^4] == 0;
    public byte ErrorCode => Data.Length >= 4 ? Data[^3] : (byte)0xFF;
    public byte[] Payload => Data.Length >= 4 ? Data[..^4] : [];

    public static EspRomResponse? Parse(byte[] f)
    {
        if (f.Length < 8 || f[0] != 0x01) return null;
        int size = f[2] | f[3] << 8;
        if (f.Length < 8 + size) return null;
        uint value = (uint)(f[4] | f[5] << 8 | f[6] << 16 | f[7] << 24);
        return new EspRomResponse(f[1], value, f[8..(8 + size)]);
    }
}

public static class EspRomPacket
{
    public const int FlashBlockSize = 0x400;
    public static readonly byte[] SyncPayload = [0x07, 0x07, 0x12, 0x20, .. Enumerable.Repeat((byte)0x55, 32)];

    public static uint Checksum(ReadOnlySpan<byte> data)
    {
        byte c = 0xEF;
        foreach (var b in data) c ^= b;
        return c;
    }

    public static byte[] Le32(params uint[] vs)
    {
        var o = new byte[vs.Length * 4];
        for (int i = 0; i < vs.Length; i++) BitConverter.TryWriteBytes(o.AsSpan(i * 4), vs[i]);
        if (!BitConverter.IsLittleEndian) throw new PlatformNotSupportedException();
        return o;
    }

    public static byte[] Request(EspRomCommand cmd, ReadOnlySpan<byte> data, uint checksum = 0)
    {
        var o = new byte[8 + data.Length];
        o[0] = 0x00;
        o[1] = (byte)cmd;
        o[2] = (byte)(data.Length & 0xFF);
        o[3] = (byte)(data.Length >> 8);
        Le32(checksum).CopyTo(o, 4);
        data.CopyTo(o.AsSpan(8));
        return o;
    }
}

/// <summary>刷写用的串口。实现：Windows SerialPort；测试里是模拟 ROM。</summary>
public interface IEspSerialTransport
{
    void Write(byte[] bytes);
    /// <summary>读取可用字节，最多等待 timeout；超时返回空数组。</summary>
    byte[] Read(TimeSpan timeout);
    void SetDtr(bool on);
    void SetRts(bool on);
    void SetBaud(int baud);
    void FlushInput();
}

public sealed class EspFlashException(string message) : Exception(message)
{
    public static EspFlashException NoSync() => new("无法进入下载模式。请按住板子上的 BOOT 键再点刷写，或换一根数据线。");
    public static EspFlashException Timeout(string step) => new($"{step} 超时，板子没有响应");
    public static EspFlashException Rom(string step, byte code) => new($"{step} 失败（错误码 0x{code:x}）");
    public static EspFlashException VerifyFailed() => new("写入后校验不一致，请重试");
    public static EspFlashException BadImage(string reason) => new($"固件文件无效：{reason}");
}

public enum EspFlashStage { Connecting, Erasing, Writing, Verifying, Done }

public sealed class EspFlasher(IEspSerialTransport port)
{
    private EspSlip.Decoder _decoder = new();
    private readonly Queue<byte[]> _pending = new();

    /// <summary>阶段与写入进度（0~1）</summary>
    public event Action<EspFlashStage, double>? Stage;
    public event Action<string>? Log;
    /// <summary>测试时设为 0 加快速度</summary>
    public TimeSpan ResetDelay { get; set; } = TimeSpan.FromMilliseconds(100);

    public void Flash(byte[] image, uint offset, int? fastBaud = 460_800, uint flashSize = 4u << 20)
    {
        if (image.Length == 0) throw EspFlashException.BadImage("文件为空");
        if (offset + (long)image.Length > flashSize) throw EspFlashException.BadImage("超过闪存大小");
        Stage?.Invoke(EspFlashStage.Connecting, 0);
        Connect();
        Command(EspRomCommand.SpiAttach, EspRomPacket.Le32(0, 0), "连接闪存");
        Command(EspRomCommand.SpiSetParams, EspRomPacket.Le32(0, flashSize, 64 * 1024, 4096, 256, 0xFFFF), "设置闪存参数");
        if (fastBaud is int baud)
        {
            Command(EspRomCommand.ChangeBaudrate, EspRomPacket.Le32((uint)baud, 0), "切换波特率");
            port.SetBaud(baud);
            Thread.Sleep(ResetDelay / 2);
            port.FlushInput();
            _decoder = new EspSlip.Decoder();
            _pending.Clear();
        }
        int block = EspRomPacket.FlashBlockSize;
        int blocks = (image.Length + block - 1) / block;
        Stage?.Invoke(EspFlashStage.Erasing, 0);
        var eraseTimeout = TimeSpan.FromSeconds(Math.Max(10, image.Length / 1_000_000.0 * 15));
        Command(EspRomCommand.FlashBegin, EspRomPacket.Le32((uint)image.Length, (uint)blocks, (uint)block, offset), "擦除闪存", eraseTimeout);
        for (int seq = 0; seq < blocks; seq++)
        {
            var chunk = new byte[block];
            Array.Fill(chunk, (byte)0xFF);
            int len = Math.Min(block, image.Length - seq * block);
            Array.Copy(image, seq * block, chunk, 0, len);
            var data = EspRomPacket.Le32((uint)block, (uint)seq, 0, 0).Concat(chunk).ToArray();
            Command(EspRomCommand.FlashData, data, $"写入第 {seq + 1} 块", TimeSpan.FromSeconds(5), EspRomPacket.Checksum(chunk));
            Stage?.Invoke(EspFlashStage.Writing, (seq + 1) / (double)blocks);
        }
        Stage?.Invoke(EspFlashStage.Verifying, 1);
        var md5 = Command(EspRomCommand.SpiFlashMd5, EspRomPacket.Le32(offset, (uint)image.Length, 0, 0), "校验",
            TimeSpan.FromSeconds(Math.Max(8, image.Length / 1_000_000.0 * 10)));
        var expected = Convert.ToHexStringLower(MD5.HashData(image));
        var p = md5.Payload;
        var got = p.Length switch
        {
            32 => Encoding.ASCII.GetString(p).ToLowerInvariant(),
            16 => Convert.ToHexStringLower(p),
            _ => throw EspFlashException.VerifyFailed(),
        };
        if (got != expected) throw EspFlashException.VerifyFailed();
        try { Command(EspRomCommand.FlashEnd, EspRomPacket.Le32(1), "结束", TimeSpan.FromSeconds(2)); } catch (EspFlashException) { }
        HardReset();
        Stage?.Invoke(EspFlashStage.Done, 1);
    }

    /// <summary>经典自动下载电路：RTS 接 EN，DTR 接 IO0。</summary>
    private void EnterBootloader()
    {
        port.SetDtr(false);
        port.SetRts(true);
        Thread.Sleep(ResetDelay);
        port.SetDtr(true);
        port.SetRts(false);
        Thread.Sleep(ResetDelay / 2);
        port.SetDtr(false);
    }

    public void HardReset()
    {
        port.SetDtr(false);
        port.SetRts(true);
        Thread.Sleep(ResetDelay);
        port.SetRts(false);
    }

    private void Connect()
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            EnterBootloader();
            port.FlushInput();
            _decoder = new EspSlip.Decoder();
            _pending.Clear();
            for (int i = 0; i < 4; i++)
            {
                port.Write(EspSlip.Encode(EspRomPacket.Request(EspRomCommand.Sync, EspRomPacket.SyncPayload)));
                var r = TryWait(EspRomCommand.Sync, TimeSpan.FromMilliseconds(100));
                if (r is { Ok: true })
                {
                    while (TryWait(EspRomCommand.Sync, TimeSpan.FromMilliseconds(100)) is not null) { }
                    Log?.Invoke($"已进入下载模式（第 {attempt + 1} 次尝试）");
                    return;
                }
            }
        }
        throw EspFlashException.NoSync();
    }

    private EspRomResponse Command(EspRomCommand cmd, byte[] data, string step, TimeSpan? timeout = null, uint checksum = 0)
    {
        port.Write(EspSlip.Encode(EspRomPacket.Request(cmd, data, checksum)));
        var r = TryWait(cmd, timeout ?? TimeSpan.FromSeconds(3)) ?? throw EspFlashException.Timeout(step);
        if (!r.Ok) throw EspFlashException.Rom(step, r.ErrorCode);
        return r;
    }

    private EspRomResponse? TryWait(EspRomCommand cmd, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (true)
        {
            while (_pending.Count > 0)
            {
                var r = EspRomResponse.Parse(_pending.Dequeue());
                if (r is not null && r.Command == (byte)cmd) return r;
            }
            var left = deadline - DateTime.UtcNow;
            if (left <= TimeSpan.Zero) return null;
            var bytes = port.Read(left < TimeSpan.FromMilliseconds(50) ? left : TimeSpan.FromMilliseconds(50));
            if (bytes.Length > 0) foreach (var f in _decoder.Feed(bytes)) _pending.Enqueue(f);
        }
    }
}
