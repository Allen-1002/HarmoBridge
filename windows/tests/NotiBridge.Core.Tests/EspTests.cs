using System.Security.Cryptography;
using System.Text;
using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

/// <summary>模拟 ESP32 ROM，与 Mac 端 FakeRom 相同。</summary>
internal sealed class FakeRom : IEspSerialTransport
{
    public byte[] Flash = Enumerable.Repeat((byte)0xFF, 4 << 20).ToArray();
    public bool Dtr, Rts, InBootloader;
    public int Baud = 115_200;
    public int? CorruptBlock;
    public int SyncIgnoredTimes;
    public int ReadCount;
    private readonly List<byte> _out = [];
    private readonly EspSlip.Decoder _dec = new();
    private int _writeOffset, _blockSize, _expectedSeq, _resetPhase;

    public void SetDtr(bool on)
    {
        Dtr = on;
        if (_resetPhase == 1 && on && Rts) _resetPhase = 2;
    }

    public void SetRts(bool on)
    {
        if (on && !Dtr) { _resetPhase = 1; InBootloader = false; }
        if (!on && Rts) { InBootloader = _resetPhase == 2 && Dtr; _resetPhase = 0; }
        Rts = on;
    }

    public void SetBaud(int baud) => Baud = baud;
    public void FlushInput() => _out.Clear();

    public byte[] Read(TimeSpan timeout)
    {
        var r = _out.ToArray();
        _out.Clear();
        return r;
    }

    public void Write(byte[] bytes)
    {
        foreach (var f in _dec.Feed(bytes)) Handle(f);
    }

    private void Reply(byte cmd, byte[]? data = null, byte status = 0, byte err = 0)
    {
        var body = (data ?? []).Concat(new byte[] { status, err, 0, 0 }).ToArray();
        var pkt = new byte[] { 0x01, cmd, (byte)(body.Length & 0xFF), (byte)(body.Length >> 8), 0, 0, 0, 0 }.Concat(body).ToArray();
        _out.AddRange(EspSlip.Encode(pkt));
    }

    private static int U32(byte[] d, int i) => BitConverter.ToInt32(d, i);

    private void Handle(byte[] f)
    {
        if (!InBootloader || f.Length < 8 || f[0] != 0) return;
        var cmd = f[1];
        var data = f[8..];
        switch (cmd)
        {
            case 0x08:
                if (SyncIgnoredTimes > 0) { SyncIgnoredTimes--; return; }
                Assert.Equal(EspRomPacket.SyncPayload, data);
                for (int i = 0; i < 3; i++) Reply(cmd);
                break;
            case 0x0D or 0x0B:
                Reply(cmd);
                break;
            case 0x0F:
                Reply(cmd);
                Baud = U32(data, 0);
                break;
            case 0x02:
                {
                    int size = U32(data, 0), off = U32(data, 12);
                    _blockSize = U32(data, 8);
                    _writeOffset = off;
                    _expectedSeq = 0;
                    Array.Fill(Flash, (byte)0xFF, off, size);
                    Reply(cmd);
                    break;
                }
            case 0x03:
                {
                    int len = U32(data, 0), seq = U32(data, 4);
                    var payload = data[16..(16 + len)];
                    uint ck = BitConverter.ToUInt32(f, 4);
                    if (seq != _expectedSeq || ck != EspRomPacket.Checksum(payload) || len != _blockSize)
                    {
                        Reply(cmd, status: 1, err: 7);
                        return;
                    }
                    if (seq == CorruptBlock) payload[0] ^= 0xFF;
                    payload.CopyTo(Flash, _writeOffset + seq * _blockSize);
                    _expectedSeq++;
                    Reply(cmd);
                    break;
                }
            case 0x13:
                {
                    int off = U32(data, 0), size = U32(data, 4);
                    var hex = Convert.ToHexStringLower(MD5.HashData(Flash.AsSpan(off, size)));
                    Reply(cmd, Encoding.ASCII.GetBytes(hex));
                    break;
                }
            case 0x04:
                Reply(cmd);
                break;
            case 0x0A:
                {
                    uint addr = (uint)U32(data, 0);
                    uint v = addr == 0x3FF5A004 ? 0x5716D344u : addr == 0x3FF5A008 ? 0x1C8Fu : 0;
                    _out.AddRange(EspSlip.Encode(new byte[] { 0x01, cmd, 4, 0 }.Concat(EspRomPacket.Le32(v)).Concat(new byte[] { 0, 0, 0, 0 }).ToArray()));
                    break;
                }
            case 0x0E:
                {
                    int off = U32(data, 0), len = U32(data, 4);
                    ReadCount++;
                    Reply(cmd, Flash[off..(off + len)]);
                    break;
                }
            default:
                Reply(cmd, status: 1, err: 5);
                break;
        }
    }
}

public class EspTests
{
    private static byte[] Image(int n) => Enumerable.Range(0, n).Select(i => (byte)(i * 7 + i / 251)).ToArray();

    [Fact]
    public void SlipRoundTrip()
    {
        byte[] data = [0x01, 0xC0, 0xDB, 0x02, 0xDB, 0xDC];
        var enc = EspSlip.Encode(data);
        Assert.Equal(new byte[] { 0xC0, 0x01, 0xDB, 0xDC, 0xDB, 0xDD, 0x02, 0xDB, 0xDD, 0xDC, 0xC0 }, enc);
        var d = new EspSlip.Decoder();
        var frames = d.Feed(Encoding.ASCII.GetBytes("ets Jun  8 2016\r\n").Concat(enc[..4]).ToArray());
        frames.AddRange(d.Feed(enc[4..].Concat(enc).ToArray()));
        Assert.Equal(2, frames.Count);
        Assert.All(frames, f => Assert.Equal(data, f));
    }

    [Fact]
    public void ChecksumAndPacket()
    {
        Assert.Equal(0xEFu, EspRomPacket.Checksum([]));
        Assert.Equal(0u, EspRomPacket.Checksum([0xEF]));
        Assert.Equal(new byte[] { 0, 3, 3, 0, 0x34, 0x12, 0, 0, 1, 2, 3 }, EspRomPacket.Request(EspRomCommand.FlashData, [1, 2, 3], 0x1234));
    }

    [Fact]
    public void FlashWritesImageAndResets()
    {
        var rom = new FakeRom { SyncIgnoredTimes = 6 };
        var img = Image(5000);
        var f = new EspFlasher(rom) { ResetDelay = TimeSpan.Zero };
        var stages = new List<EspFlashStage>();
        f.Stage += (s, _) => stages.Add(s);
        f.Flash(img, 0x1000);
        Assert.Equal(img, rom.Flash[0x1000..(0x1000 + img.Length)]);
        Assert.Equal(0xFF, rom.Flash[0x1000 + img.Length]);
        Assert.Equal(460_800, rom.Baud);
        Assert.False(rom.InBootloader);
        Assert.Equal(EspFlashStage.Connecting, stages[0]);
        Assert.Equal(EspFlashStage.Done, stages[^1]);
    }

    [Fact]
    public void VerifyFailureIsReported()
    {
        var rom = new FakeRom { CorruptBlock = 2 };
        var f = new EspFlasher(rom) { ResetDelay = TimeSpan.Zero };
        var e = Assert.Throws<EspFlashException>(() => f.Flash(Image(4096), 0x1000, null));
        Assert.Contains("校验", e.Message);
    }

    [Fact]
    public void NoSync()
    {
        var rom = new FakeRom { SyncIgnoredTimes = int.MaxValue };
        var f = new EspFlasher(rom) { ResetDelay = TimeSpan.Zero };
        var e = Assert.Throws<EspFlashException>(() => f.Flash(Image(10), 0x1000));
        Assert.Contains("下载模式", e.Message);
    }

    [Fact]
    public void ParseEvents()
    {
        Assert.Equal(new Esp32Event.Hello("1.2.0", "aa:bb:cc:dd:ee:ff", 1),
            Esp32LinkParser.Parse("HB-ESP32 1.2.0 chip=esp32 ble=aa:bb:cc:dd:ee:ff proto=1\r"));
        Assert.Equal(new Esp32Event.State(new Esp32LinkState("ready", "11:22:33:44:55:66", 1, false)),
            Esp32LinkParser.Parse("""@{"t":"state","ble":"ready","peer":"11:22:33:44:55:66","bonds":1,"pairing":false}"""));
        Assert.Null(Esp32LinkParser.Parse("W (123) nb: x"));
        Assert.Null(Esp32LinkParser.Parse("@{broken"));
        Assert.Null(Esp32LinkParser.Parse("""@{"t":"notif","uid":-1}"""));
        Assert.Equal(new Esp32Event.Removed(9), Esp32LinkParser.Parse("""@{"t":"removed","uid":9}"""));
        Assert.Equal(new Esp32Event.Removed(9, "51:a8:27:cd:73:e0"), Esp32LinkParser.Parse("""@{"t":"removed","uid":9,"peer":"51:a8:27:cd:73:e0"}"""));
        Assert.Equal(new Esp32Event.Error("auth", "x"), Esp32LinkParser.Parse("""@{"t":"err","code":"auth","msg":"x"}"""));
    }

    [Fact]
    public void ParseNotification()
    {
        var e = Esp32LinkParser.Parse("""@{"t":"notif","ev":"add","uid":4294967295,"flags":4,"cat":4,"app":"com.tencent.xin","appName":"微信","title":"张三","sub":"群聊","msg":"晚上吃饭？\n\"好\"","date":"20261110T094500","pos":"","neg":"清除","peer":"51:a8:27:cd:73:e0"}""");
        var n = Assert.IsType<Esp32Event.Notification>(e).Item;
        Assert.Equal("51:a8:27:cd:73:e0", n.Peer);
        Assert.Equal(4294967295u, n.Uid);
        Assert.True(n.PreExisting);
        var m = n.Mirrored();
        Assert.Equal("ios-4294967295", m.Id);
        Assert.Equal("微信", m.AppName);
        Assert.Equal("群聊\n晚上吃饭？\n\"好\"", m.Text);
        Assert.Equal(new DateTime(2026, 11, 10, 9, 45, 0), m.Time.LocalDateTime);
    }

    [Fact]
    public void ParseCallEvents()
    {
        Assert.Equal(new Esp32Event.Hfp(new HfpLink("connected", "1c:8f:57:16:d3:00", "Allen 的 iPhone", "msbc", true, 4, 5, "中国移动", false)),
            Esp32LinkParser.Parse("""@{"t":"hfp","state":"connected","peer":"1c:8f:57:16:d3:00","name":"Allen 的 iPhone","audio":"msbc","audioTo":"pc","battery":4,"signal":5,"operator":"中国移动","discoverable":false}"""));
        Assert.Equal(new Esp32Event.Call(new PhoneCall("incoming", "+8613800000000", 0)),
            Esp32LinkParser.Parse("""@{"t":"call","state":"incoming","number":"+8613800000000","call":0,"setup":1,"held":0}"""));
        var phones = Assert.IsType<Esp32Event.Phones>(Esp32LinkParser.Parse("""@{"t":"phones","list":[{"addr":"aa:bb:cc:dd:ee:ff","name":"","connected":false}]}""")).List;
        Assert.Equal("手机", Assert.Single(phones).DisplayName);
        Assert.Equal(new Esp32Event.PairCode("012345"), Esp32LinkParser.Parse("""@{"t":"pair_code","code":"012345"}"""));
    }

    [Fact]
    public void ParseBonds()
    {
        var e = Esp32LinkParser.Parse("""@{"t":"bonds","list":[{"addr":"51:a8:27:cd:73:e0","name":"Allen 的 iPhone","connected":true,"ready":true},{"addr":"11:22:33:44:55:66","name":"","connected":false,"ready":false},{"name":"x"}]}""");
        var list = Assert.IsType<Esp32Event.Bonds>(e).List;
        Assert.Equal(2, list.Count);
        Assert.Equal(new PairedIphone("51:a8:27:cd:73:e0", "Allen 的 iPhone", true, true), list[0]);
        Assert.Equal("iPhone", list[1].DisplayName);
    }

    [Fact]
    public void Lines()
    {
        var s = new LineSplitter();
        Assert.Equal(["ab"], s.Feed(Encoding.UTF8.GetBytes("ab\nc")));
        Assert.Equal(["c中"], s.Feed(Encoding.UTF8.GetBytes("中\n")));
    }

    [Fact]
    public void Otp()
    {
        Assert.Equal("482913", OtpExtractor.Extract("", "【某服务】您的验证码是 482913，5 分钟内有效"));
        Assert.Equal("7731", OtpExtractor.Extract("Your code", "Use 7731 to sign in. Order 20261110"));
        Assert.Equal("", OtpExtractor.Extract("张三", "明天 1530 见"));
        Assert.True(OtpExtractor.IsFinance("com.icbc.iphoneclient", "", ""));
        Assert.False(OtpExtractor.IsFinance("com.apple.MobileSMS", "", "验证码 1234"));
    }
}

public class EspBackupTests
{
    private const string Mac = "1c:8f:57:16:d3:44";
    private static readonly TimeSpan Zero = TimeSpan.Zero;

    private static EspBackupStore TempStore() => new(Path.Combine(Path.GetTempPath(), "esp-backup-" + Guid.NewGuid()));

    private static void FakeApp(FakeRom rom, string name)
    {
        EspRomPacket.Le32(0xABCD5432).CopyTo(rom.Flash, 0x10020);
        var n = new byte[32];
        Encoding.UTF8.GetBytes(name).CopyTo(n, 0);
        n.CopyTo(rom.Flash, 0x10020 + 0x30);
    }

    [Fact]
    public void BackupFlashAgainAndRestore()
    {
        var rom = new FakeRom();
        for (int i = 0x1000; i < 0x6000; i++) rom.Flash[i] = (byte)(i & 0x7F);
        FakeApp(rom, "factory_demo");
        for (int i = 0x300000; i < 0x300100; i++) rom.Flash[i] = 0x42;
        var original = (byte[])rom.Flash.Clone();
        var store = TempStore();
        var fw1 = Enumerable.Repeat((byte)0x11, 0x20000).ToArray();
        Assert.Equal(EspFirmwareInstaller.BackupOutcome.Created, EspFirmwareInstaller.Install(fw1, rom, store, resetDelay: Zero));
        Assert.True(rom.ReadCount < 3 * 1024 + 10);
        Assert.Equal(0x21000u, store.Info(Mac)!.TouchedEnd);

        FakeApp(rom, "notibridge_esp32");
        var fw2 = Enumerable.Repeat((byte)0x22, 0x40000).ToArray();
        Assert.Equal(EspFirmwareInstaller.BackupOutcome.Kept, EspFirmwareInstaller.Install(fw2, rom, store, resetDelay: Zero));
        Assert.Equal(0x41000u, store.Info(Mac)!.TouchedEnd);

        for (int i = 0x9000; i < 0x9100; i++) rom.Flash[i] = 0x99;
        FakeApp(rom, "notibridge_esp32");
        var fw3 = Enumerable.Repeat((byte)0x33, 0x40000).ToArray();
        Assert.Equal(EspFirmwareInstaller.BackupOutcome.Kept, EspFirmwareInstaller.Install(fw3, rom, store, resetDelay: Zero));
        Assert.Equal(0x99, rom.Flash[0x9000]);
        Assert.Equal(0x33, rom.Flash[0x8FFF]);
        Assert.Equal(0x33, rom.Flash[0x10000]);
        EspFirmwareInstaller.Restore(rom, store, resetDelay: Zero);
        Assert.Equal(original, rom.Flash);
        Assert.False(rom.InBootloader);
    }

    [Fact]
    public void NoBackupWhenAlreadyNotiBridge()
    {
        var rom = new FakeRom();
        FakeApp(rom, "notibridge_esp32");
        var store = TempStore();
        Assert.Equal(EspFirmwareInstaller.BackupOutcome.AlreadyNotiBridge, EspFirmwareInstaller.Install([1, 2, 3], rom, store, resetDelay: Zero));
        Assert.Null(store.Info(Mac));
        Assert.Throws<EspFlashException>(() => EspFirmwareInstaller.Restore(rom, store, resetDelay: Zero));
    }

    [Fact]
    public void BlankBoardAndCorruptBackup()
    {
        var rom = new FakeRom();
        var store = TempStore();
        Assert.Equal(EspFirmwareInstaller.BackupOutcome.Created, EspFirmwareInstaller.Install([1, 2, 3], rom, store, resetDelay: Zero));
        Assert.True(store.Info(Mac)!.WasBlank);
        Assert.Equal(2, rom.ReadCount);
        var path = store.ImagePath(Mac);
        var data = File.ReadAllBytes(path);
        data[10] ^= 1;
        File.WriteAllBytes(path, data);
        Assert.Throws<EspFlashException>(() => EspFirmwareInstaller.Restore(rom, store, resetDelay: Zero));
        Assert.Single(store.All());
    }
}

public class UsbSerialChipTests
{
    [Fact]
    public void Names()
    {
        Assert.Equal("CH340", UsbSerialChip.Name(0x1A86, 0x7522));
        Assert.Equal("CH9102", UsbSerialChip.Name(0x1A86, 0x55D4));
        Assert.Null(UsbSerialChip.Name(0x1A86, 0x8091));
        Assert.Equal("CP210x", UsbSerialChip.Name(0x10C4, 0xEA60));
        Assert.Null(UsbSerialChip.Name(null, null));
        var m = UsbSerialChip.DriverMissingMessage(["CH340", "CH340"]);
        Assert.Contains("（CH340）", m);
        Assert.DoesNotContain("http", m);
    }
}
