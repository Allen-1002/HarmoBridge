using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace NotiBridge.Core;

/// <summary>
/// 刷写前自动备份板子上原有的固件，之后可以一键还原。与 Mac 端 EspBackup.swift 一致：
/// 每块板子（按芯片 MAC）只备份一次；板子上已是 NotiBridge 固件时不备份；全 0xFF 的 64KB 块跳过；
/// 还原时只写回 NotiBridge 改动过的 [0x1000, TouchedEnd)。
/// </summary>
public sealed record EspBackupInfo(string Mac, DateTimeOffset CreatedAt, uint FlashSize, string Sha256, uint TouchedEnd, bool WasBlank);

public sealed class EspBackupStore(string directory)
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public string Directory { get; } = directory;

    private static string FileName(string mac) => mac.Replace(":", "");
    public string ImagePath(string mac) => Path.Combine(Directory, FileName(mac) + ".bin");
    public string InfoPath(string mac) => Path.Combine(Directory, FileName(mac) + ".json");

    public EspBackupInfo? Info(string mac)
    {
        try { return JsonSerializer.Deserialize<EspBackupInfo>(File.ReadAllText(InfoPath(mac)), Json); }
        catch (Exception) { return null; }
    }

    public List<EspBackupInfo> All()
    {
        if (!System.IO.Directory.Exists(Directory)) return [];
        var list = new List<EspBackupInfo>();
        foreach (var f in System.IO.Directory.GetFiles(Directory, "*.json"))
        {
            try { if (JsonSerializer.Deserialize<EspBackupInfo>(File.ReadAllText(f), Json) is { } i) list.Add(i); }
            catch (Exception) { }
        }
        return list.OrderByDescending(i => i.CreatedAt).ToList();
    }

    public void Save(byte[] image, EspBackupInfo info)
    {
        System.IO.Directory.CreateDirectory(Directory);
        WriteAtomic(ImagePath(info.Mac), image);
        SaveInfo(info);
    }

    public void SaveInfo(EspBackupInfo info)
    {
        System.IO.Directory.CreateDirectory(Directory);
        WriteAtomic(InfoPath(info.Mac), Encoding.UTF8.GetBytes(JsonSerializer.Serialize(info, Json)));
    }

    private static void WriteAtomic(string path, byte[] data)
    {
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, true);
    }

    /// <summary>读取备份并核对 SHA-256</summary>
    public (EspBackupInfo Info, byte[] Image) Load(string mac)
    {
        var info = Info(mac) ?? throw EspFlashException.BadImage("这块板子没有备份");
        var data = File.ReadAllBytes(ImagePath(mac));
        if (Sha256Hex(data) != info.Sha256 || data.Length != info.FlashSize) throw EspFlashException.BadImage("备份文件已损坏");
        return (info, data);
    }

    public static string Sha256Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
}

public static class EspFirmwareInstaller
{
    public const uint FirmwareOffset = 0x1000;
    private const uint AppOffset = 0x10000;
    private const string ProjectName = "notibridge_esp32";
    private const int BlockSize = 64 * 1024;

    public enum BackupOutcome { Created, Kept, AlreadyNotiBridge }

    private static bool HasNotiBridgeFirmware(EspFlasher f)
    {
        var d = f.Read(AppOffset + 0x20, 0x50);
        if (BitConverter.ToUInt32(d, 0) != 0xABCD5432) return false;
        var name = d.AsSpan(0x30, 0x20);
        int z = name.IndexOf((byte)0);
        return Encoding.UTF8.GetString(z >= 0 ? name[..z] : name) == ProjectName;
    }

    private static (byte[] Image, bool Blank) ReadAll(EspFlasher f, uint flashSize, Action<double> progress)
    {
        var emptyMd5 = EspFlasher.Md5Hex(Enumerable.Repeat((byte)0xFF, BlockSize).ToArray());
        var image = new byte[flashSize];
        Array.Fill(image, (byte)0xFF);
        var nonEmpty = Enumerable.Range(0, (int)flashSize / BlockSize).Where(b => f.Md5((uint)(b * BlockSize), BlockSize) != emptyMd5).ToList();
        for (int i = 0; i < nonEmpty.Count; i++)
        {
            int b = nonEmpty[i];
            int idx = i;
            f.Read((uint)(b * BlockSize), BlockSize, p => progress((idx + p) / nonEmpty.Count)).CopyTo(image, b * BlockSize);
        }
        return (image, nonEmpty.Count == 0);
    }

    private static EspFlasher Open(IEspSerialTransport port, Action<EspFlashStage, double>? onStage, Action<string>? log, TimeSpan? resetDelay)
    {
        var f = new EspFlasher(port);
        if (resetDelay is { } d) f.ResetDelay = d;
        if (onStage is not null) f.Stage += onStage;
        if (log is not null) f.Log += log;
        return f;
    }

    /// <summary>刷写固件。第一次刷写某块板子时先备份原固件。</summary>
    public static BackupOutcome Install(byte[] image, IEspSerialTransport port, EspBackupStore store,
        Action<EspFlashStage, double>? onStage = null, Action<string>? log = null, TimeSpan? resetDelay = null)
    {
        var f = Open(port, onStage, log, resetDelay);
        f.Begin();
        var mac = f.ReadMac();
        uint end = FirmwareOffset + (uint)image.Length;
        BackupOutcome outcome;
        if (store.Info(mac) is { } info)
        {
            if (end > info.TouchedEnd) store.SaveInfo(info with { TouchedEnd = end });
            outcome = BackupOutcome.Kept;
        }
        else if (HasNotiBridgeFirmware(f))
        {
            outcome = BackupOutcome.AlreadyNotiBridge;
        }
        else
        {
            onStage?.Invoke(EspFlashStage.BackingUp, 0);
            var (backup, blank) = ReadAll(f, f.FlashSize, p => onStage?.Invoke(EspFlashStage.BackingUp, p));
            store.Save(backup, new EspBackupInfo(mac, DateTimeOffset.Now, f.FlashSize, EspBackupStore.Sha256Hex(backup), end, blank));
            log?.Invoke($"已备份板子 {mac} 的原固件");
            outcome = BackupOutcome.Created;
        }
        f.Write(image, FirmwareOffset);
        f.Finish();
        return outcome;
    }

    /// <summary>还原原固件：只写回 NotiBridge 改动过的 [0x1000, TouchedEnd)。</summary>
    public static EspBackupInfo Restore(IEspSerialTransport port, EspBackupStore store,
        Action<EspFlashStage, double>? onStage = null, Action<string>? log = null, TimeSpan? resetDelay = null)
    {
        var f = Open(port, onStage, log, resetDelay);
        f.Begin();
        var mac = f.ReadMac();
        var (info, backup) = store.Load(mac);
        int end = (int)Math.Min(info.FlashSize, (info.TouchedEnd + 0xFFFu) & ~0xFFFu);
        f.Write(backup[(int)FirmwareOffset..end], FirmwareOffset);
        f.Finish();
        log?.Invoke($"已把板子 {mac} 还原为原固件");
        return info;
    }
}
