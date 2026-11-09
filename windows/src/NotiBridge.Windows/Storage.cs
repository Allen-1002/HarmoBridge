using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using NotiBridge.Core;

namespace NotiBridge.Windows;

internal static class Paths
{
    public static string DataDir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NotiBridge");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public static string CacheDir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NotiBridge");
            Directory.CreateDirectory(d);
            return d;
        }
    }
}

/// <summary>本机设置（%APPDATA%\NotiBridge\settings.json）。不含任何密钥。</summary>
public sealed class AppSettings
{
    public string ComputerId { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public int Port { get; set; } = BridgeServer.DefaultPort;
    public bool Onboarded { get; set; }
    public bool Paused { get; set; }
    public bool CopyOtp { get; set; } = true;
    public bool ShowContentInList { get; set; }
    /// <summary>首次运行时选择了“不安装”（以免安装方式运行）</summary>
    public bool InstallDeclined { get; set; }
    /// <summary>使用方式："software"（纯软件）或 "esp32"（使用 ESP32 通话模块）</summary>
    public string UseMode { get; set; } = "software";
    public double SettingsUpdatedAt { get; set; }
    /// <summary>自动检查更新（GitHub Releases）</summary>
    public bool UpdateAutoCheck { get; set; } = true;
    /// <summary>发现新版本后自动下载并安装</summary>
    public bool UpdateAutoInstall { get; set; } = true;
    public SyncFilter Filter { get; set; } = new();
    /// <summary>用户在电脑上给手机起的名字（deviceId -> 名字），只保存在本机</summary>
    public Dictionary<string, string> DeviceAliases { get; set; } = new();

    private static string FilePath => Path.Combine(Paths.DataDir, "settings.json");
    private static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Opts) ?? new AppSettings();
        }
        catch (Exception)
        {
            // 文件损坏时用默认值
        }
        var s = new AppSettings();
        s.Save();
        return s;
    }

    public void Save()
    {
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, Opts));
        File.Move(tmp, FilePath, true);
    }
}

/// <summary>
/// 已配对手机的密钥：用 Windows DPAPI（当前用户）加密后存在 %APPDATA%\NotiBridge\paired.json，
/// 只有当前 Windows 账户能解密，相当于 Mac 端的登录钥匙串。线程安全。
/// </summary>
public sealed class DpapiKeyStore : IPairedKeyStore
{
    public sealed record Device(string Id, string Name, DateTimeOffset PairedAt);

    private sealed class Entry
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public DateTimeOffset PairedAt { get; set; }
        public string ProtectedKey { get; set; } = "";
    }

    private static readonly byte[] Entropy = "NotiBridge.Windows.paired.v1"u8.ToArray();
    private readonly object _gate = new();
    private readonly string _file = Path.Combine(Paths.DataDir, "paired.json");
    private List<Entry> _entries;

    public DpapiKeyStore()
    {
        _entries = Read();
    }

    public byte[]? KeyFor(string deviceId)
    {
        lock (_gate)
        {
            var e = _entries.FirstOrDefault(x => x.Id == deviceId);
            if (e is null) return null;
            try
            {
                var key = ProtectedData.Unprotect(Convert.FromBase64String(e.ProtectedKey), Entropy, DataProtectionScope.CurrentUser);
                return key.Length == 32 ? key : null;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    public void Save(string deviceId, string name, byte[] key)
    {
        lock (_gate)
        {
            _entries.RemoveAll(x => x.Id == deviceId);
            _entries.Add(new Entry
            {
                Id = deviceId, Name = name, PairedAt = DateTimeOffset.Now,
                ProtectedKey = Convert.ToBase64String(ProtectedData.Protect(key, Entropy, DataProtectionScope.CurrentUser)),
            });
            Write();
        }
    }

    public void Remove(string deviceId)
    {
        lock (_gate)
        {
            _entries.RemoveAll(x => x.Id == deviceId);
            Write();
        }
    }

    public IReadOnlyList<Device> Devices()
    {
        lock (_gate) return _entries.Select(e => new Device(e.Id, e.Name, e.PairedAt)).ToList();
    }

    private List<Entry> Read()
    {
        try
        {
            if (File.Exists(_file)) return JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(_file)) ?? [];
        }
        catch (Exception)
        {
            // 损坏时视为没有配对
        }
        return [];
    }

    private void Write()
    {
        var tmp = _file + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(_entries, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, _file, true);
    }
}
