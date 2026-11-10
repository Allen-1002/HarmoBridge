using System.IO;
using System.IO.Ports;
using NotiBridge.Core;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;

namespace NotiBridge.Windows;

/// <summary>一个可能是 ESP32 的 USB 串口。</summary>
public sealed record Esp32Port(string Port, string Name, string? Chip)
{
    public bool IsLikelyEsp32 => Chip is not null;
    public string Label => Chip is null ? $"{Port} · {Name}" : $"{Port} · {Name}（{Chip}）";
    public override string ToString() => Label;
}

/// <summary>
/// ESP32 模块：检测硬件、检测/刷写固件，并与固件保持串口连接（接收 iPhone 通知），与 Mac 端 Esp32Manager 一致。
/// 固件握手：以 115200 波特率发送 "HB?\n"，NotiBridge 固件回复 "HB-ESP32 &lt;版本&gt; ..."。串口协议见 docs/esp32-serial.md。
/// </summary>
public sealed partial class Esp32Manager : ObservableObject
{
    /// <summary>合并镜像（bootloader + 分区表 + 应用）从 0x1000 开始</summary>
    public const uint FirmwareOffset = 0x1000;
    /// <summary>固件不打包进程序：需要时从 GitHub 的固件 Release（firmware-v*）下载，校验签名后刷写。缓存在 %LOCALAPPDATA%\NotiBridge\esp32-firmware。</summary>
    public static readonly string FirmwareCacheDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NotiBridge", "esp32-firmware");
    /// <summary>总是可以刷写（点刷写时再下载）</summary>
    public const bool FirmwareAvailable = true;

    private FirmwareFeed.Firmware? _latestFirmware;
    private DateTime _feedCheckedAt;
    /// <summary>GitHub 上最新的固件（null = 还没查到）</summary>
    public FirmwareFeed.Firmware? LatestFirmware
    {
        get => _latestFirmware;
        private set { Set(ref _latestFirmware, value); Raise(nameof(NeedsFirmwareUpdate)); Raise(nameof(UpdateFirmwareText)); Raise(nameof(LatestFirmwareVersion)); }
    }
    public string? LatestFirmwareVersion => _latestFirmware?.Version;

    private static readonly System.Net.Http.HttpClient Http = NewHttp();

    private static System.Net.Http.HttpClient NewHttp()
    {
        var c = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd(UpdateCore.UserAgent);
        c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return c;
    }

    /// <summary>查询 GitHub 上最新的固件（最多每小时一次，force 时立即查）</summary>
    public async Task<FirmwareFeed.Firmware?> RefreshFirmwareFeedAsync(bool force = false)
    {
        if (!force && _latestFirmware is not null && DateTime.UtcNow - _feedCheckedAt < TimeSpan.FromHours(1)) return _latestFirmware;
        try
        {
            if (FirmwareFeed.Latest(await Http.GetStringAsync(FirmwareFeed.ReleasesUrl)) is { } fw)
            {
                LatestFirmware = fw;
                _feedCheckedAt = DateTime.UtcNow;
            }
        }
        catch (Exception e)
        {
            LogLine?.Invoke($"查询 ESP32 固件失败：{e.Message}");
        }
        return _latestFirmware;
    }

    /// <summary>下载并校验固件；已缓存且校验通过的直接用。没网时用缓存里最新的。</summary>
    private async Task<(string Version, byte[] Image)> ObtainFirmwareAsync()
    {
        Directory.CreateDirectory(FirmwareCacheDir);
        byte[]? Cached(string v)
        {
            try
            {
                var img = File.ReadAllBytes(Path.Combine(FirmwareCacheDir, FirmwareFeed.AssetName(v)));
                FirmwareFeed.Verify(img, v, File.ReadAllBytes(Path.Combine(FirmwareCacheDir, v + ".sums")),
                    File.ReadAllBytes(Path.Combine(FirmwareCacheDir, v + ".sig")));
                return img;
            }
            catch (Exception) { return null; }
        }
        if (await RefreshFirmwareFeedAsync(force: true) is { } fw)
        {
            if (Cached(fw.Version) is { } c) return (fw.Version, c);
            var img = await Http.GetByteArrayAsync(fw.Image.BrowserDownloadUrl);
            var sums = await Http.GetByteArrayAsync(fw.Sums.BrowserDownloadUrl);
            var sig = await Http.GetByteArrayAsync(fw.Signature.BrowserDownloadUrl);
            FirmwareFeed.Verify(img, fw.Version, sums, sig);
            File.WriteAllBytes(Path.Combine(FirmwareCacheDir, FirmwareFeed.AssetName(fw.Version)), img);
            File.WriteAllBytes(Path.Combine(FirmwareCacheDir, fw.Version + ".sums"), sums);
            File.WriteAllBytes(Path.Combine(FirmwareCacheDir, fw.Version + ".sig"), sig);
            return (fw.Version, img);
        }
        var versions = Directory.GetFiles(FirmwareCacheDir, "NotiBridge-ESP32-*.bin")
            .Select(f => Path.GetFileNameWithoutExtension(f)["NotiBridge-ESP32-".Length..])
            .OrderByDescending(v => v, Comparer<string>.Create((a, b) => UpdateCore.CompareVersions(a, b) ?? 0));
        foreach (var v in versions) if (Cached(v) is { } c) return (v, c);
        throw new InvalidOperationException("没有网络，也没有下载过的固件");
    }

    private readonly AppSettings _settings;
    private IReadOnlyList<Esp32Port> _ports = [];
    private Esp32Port? _selected;
    private string _message = "";
    private string _firmwareText = "";
    private bool _busy;
    private bool _firmwareMissing;
    private bool _firmwareOk;
    private string _firmwareVersion = "";
    private double _flashProgress;
    private bool _flashing;
    private Esp32LinkState? _link;
    private string _linkError = "";

    private Thread? _linkThread;
    private readonly object _linkLock = new();
    private bool _linkStop;
    private SerialPortTransport? _linkPort;

    /// <summary>收到固件事件（在界面线程上调用）</summary>
    public event Action<Esp32Event>? Event;
    public event Action<string>? LogLine;

    public Esp32Manager(AppSettings settings)
    {
        _settings = settings;
        // 插拔板子后串口会变（例如 COM3 → COM5）：每 2 秒看一次串口列表，变了就重新检测
        _portWatch.Tick += (_, _) => RefreshPortsIfChanged();
        _portWatch.Start();
    }

    private readonly System.Windows.Threading.DispatcherTimer _portWatch = new() { Interval = TimeSpan.FromSeconds(2) };
    private string[] _knownPortNames = [];

    /// <summary>串口列表有变化时重新检测；正在用的串口没了或换了板子，就把连接切到新串口。返回是否有变化。</summary>
    public bool RefreshPortsIfChanged()
    {
        if (Busy || Flashing) return false;
        var names = SerialPort.GetPortNames().Distinct().Order().ToArray();
        if (names.SequenceEqual(_knownPortNames)) return false;
        var before = Selected?.Port;
        Scan();
        if (Selected?.Port != before)
        {
            StopLink();
            if (Selected is not null) _ = CheckFirmwareAsync();
        }
        else if (UseEsp32 && Selected is not null && _linkThread is null)
        {
            StartLink();
        }
        return true;
    }

    public bool UseEsp32
    {
        get => _settings.UseMode == "esp32";
        set
        {
            _settings.UseMode = value ? "esp32" : "software";
            _settings.Save();
            Raise();
            Raise(nameof(UseSoftware));
            Raise(nameof(ShowIphone));
            if (value) StartLinkIfPossible(); else StopLink();
        }
    }

    public bool UseSoftware
    {
        get => !UseEsp32;
        set => UseEsp32 = !value;
    }

    public IReadOnlyList<Esp32Port> Ports { get => _ports; private set { Set(ref _ports, value); Raise(nameof(HasPorts)); } }
    public bool HasPorts => _ports.Count > 0;
    public Esp32Port? Selected
    {
        get => _selected;
        set
        {
            if (!Set(ref _selected, value) || value is null) return;
            _settings.Esp32Port = value.Port;
            _settings.Save();
        }
    }
    public string Message { get => _message; private set => Set(ref _message, value); }
    public string FirmwareText { get => _firmwareText; private set => Set(ref _firmwareText, value); }
    public bool Busy { get => _busy; private set { Set(ref _busy, value); Raise(nameof(NotBusy)); Raise(nameof(CanFlash)); } }
    public bool NotBusy => !_busy;
    public bool CanFlash => !_busy && FirmwareAvailable;
    public bool FirmwareMissing { get => _firmwareMissing; private set => Set(ref _firmwareMissing, value); }
    public bool FirmwareOk { get => _firmwareOk; private set { Set(ref _firmwareOk, value); Raise(nameof(ShowIphone)); Raise(nameof(NeedsFirmwareUpdate)); } }
    public bool Scanned { get; private set; }
    public double FlashProgress { get => _flashProgress; private set => Set(ref _flashProgress, value); }
    public bool Flashing { get => _flashing; private set => Set(ref _flashing, value); }
    /// <summary>GitHub 上有比板子上更新的固件</summary>
    public bool NeedsFirmwareUpdate => FirmwareOk && _latestFirmware is { } f && UpdateCore.IsNewer(f.Version, _firmwareVersion);
    public string UpdateFirmwareText => $"有新固件 {_latestFirmware?.Version}";

    // ---- iPhone 连接状态 ----
    public Esp32LinkState? Link
    {
        get => _link;
        private set
        {
            Set(ref _link, value);
            Raise(nameof(LinkText));
            Raise(nameof(PairHintVisible));
            Raise(nameof(HasBonds));
        }
    }
    public bool ShowIphone => UseEsp32 && FirmwareOk;
    private string _iphoneProblem = "";
    public string LinkText => _link is { } l
        ? (!l.Ready && _iphoneProblem.Length > 0 ? $"{l.Label}：{_iphoneProblem}" : l.Label)
        : (_linkError.Length > 0 ? _linkError : "正在连接 ESP32…");
    public bool PairHintVisible => _link is { } l && (l.Bonds == 0 || l.Pairing);
    public bool HasBonds => _link is { Bonds: > 0 };

    public void Scan()
    {
        Scanned = true;
        if (Link is null)
        {
            FirmwareText = "";
            FirmwareMissing = false;
            FirmwareOk = false;
        }
        var list = ListPorts().OrderBy(p => p.IsLikelyEsp32 ? 0 : 1).ThenBy(p => p.Port).ToList();
        Ports = list;
        // 记住的串口只有在仍然像 ESP32（或根本没有像 ESP32 的串口）时才沿用，否则换到新插上的板子
        var remembered = list.FirstOrDefault(p => p.Port == _settings.Esp32Port);
        Selected = remembered is { IsLikelyEsp32: true } ? remembered
            : list.FirstOrDefault(p => p.IsLikelyEsp32) ?? remembered ?? list.FirstOrDefault();
        _knownPortNames = SerialPort.GetPortNames().Distinct().Order().ToArray();
        var missing = list.Any(p => p.IsLikelyEsp32) ? [] : UsbSerialChipsWithoutDriver();
        Message = missing.Count > 0 ? UsbSerialChip.DriverMissingMessage(missing)
            : list.Count == 0 ? UsbSerialChip.NotFoundMessage
            : list.Any(p => p.IsLikelyEsp32) ? "已找到 ESP32 模块" : "找到串口，但无法确认是 ESP32";
    }

    /// <summary>检测固件：发送握手，2 秒内收到 NotiBridge 固件的回复即成功。检测期间暂停串口连接。</summary>
    public async Task CheckFirmwareAsync()
    {
        if (Selected is not { } port) return;
        Busy = true;
        FirmwareText = "正在检测…";
        FirmwareMissing = false;
        FirmwareOk = false;
        StopLink();
        var (ok, text) = await Task.Run(() => Handshake(port.Port));
        Busy = false;
        if (ok)
        {
            SetFound(text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).FirstOrDefault() ?? "?");
            if (UseEsp32) StartLink();
        }
        else
        {
            FirmwareText = $"未检测到固件：{text}";
            FirmwareMissing = true;
        }
    }

    private void SetFound(string version)
    {
        _firmwareVersion = version;
        _ = RefreshFirmwareFeedAsync();
        FirmwareText = $"已检测到 NotiBridge 固件 {version}";
        FirmwareMissing = false;
        FirmwareOk = true;
    }

    /// <summary>原固件备份（不在程序数据目录里，“清除所有数据”不会删掉）</summary>
    public static readonly EspBackupStore BackupStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NotiBridge ESP32 Backups"));

    private int _backupCount = BackupStore.All().Count;
    public bool HasBackups => _backupCount > 0;
    public string BackupText => $"已备份 {_backupCount} 块板子的原固件";

    private static string StageText(EspFlashStage s, double p, bool restoring) => s switch
    {
        EspFlashStage.Connecting => "正在进入下载模式…",
        EspFlashStage.BackingUp => $"正在备份原固件 {(int)(p * 100)}%（只在第一次刷写时备份）",
        EspFlashStage.Erasing => "正在擦除…",
        EspFlashStage.Writing => $"正在{(restoring ? "还原" : "写入")} {(int)(p * 100)}%",
        EspFlashStage.Verifying => "正在校验…",
        _ => "完成",
    } + "（不要拔掉板子）";

    /// <summary>刷写随程序打包的固件（ESP32 ROM 下载协议，不需要 esptool）。第一次刷写某块板子前自动备份原固件。</summary>
    public async void Flash()
    {
        if (Selected is null) return;
        byte[] image;
        string version;
        Busy = true;
        FirmwareText = "正在下载固件…";
        try
        {
            (version, image) = await ObtainFirmwareAsync();
        }
        catch (Exception e)
        {
            Busy = false;
            FirmwareText = $"无法下载固件（{e.Message}）。请检查网络后重试。";
            FirmwareMissing = true;
            return;
        }
        Busy = false;
        LogLine?.Invoke($"开始刷写 ESP32 固件 {version}（{image.Length / 1024} KB）");
        var ok = await RunOnBoard(false, (t, stage, log) =>
            EspFirmwareInstaller.Install(image, t, BackupStore, stage, log) switch
            {
                EspFirmwareInstaller.BackupOutcome.Created => "ESP32 固件刷写完成，原固件已备份，可以随时还原",
                EspFirmwareInstaller.BackupOutcome.Kept => "ESP32 固件刷写完成（原固件备份已存在，保留不动）",
                _ => "ESP32 固件刷写完成（板子上原本就是 NotiBridge 固件，没有可备份的原固件）",
            });
        if (ok)
        {
            await Task.Delay(1500);
            await CheckFirmwareAsync();
        }
    }

    /// <summary>把板子还原为第一次刷写 NotiBridge 之前的原固件。</summary>
    public async void RestoreOriginal()
    {
        LogLine?.Invoke("开始还原 ESP32 原固件");
        var ok = await RunOnBoard(true, (t, stage, log) =>
            $"已还原为原固件（备份于 {EspFirmwareInstaller.Restore(t, BackupStore, stage, log).CreatedAt.LocalDateTime:g}）");
        if (ok) FirmwareText = "";
    }

    public void RevealBackups()
    {
        Directory.CreateDirectory(BackupStore.Directory);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", BackupStore.Directory) { UseShellExecute = true });
    }

    private async Task<bool> RunOnBoard(bool restoring,
        Func<SerialPortTransport, Action<EspFlashStage, double>, Action<string>, string> work)
    {
        if (Selected is not { } port) return false;
        StopLink();
        Busy = true;
        Flashing = true;
        FirmwareMissing = false;
        FirmwareOk = false;
        FlashProgress = 0;
        FirmwareText = "正在进入下载模式…（不要拔掉板子）";
        var d = System.Windows.Application.Current?.Dispatcher;
        var (text, error) = await Task.Run<(string?, string?)>(() =>
        {
            try
            {
                using var t = new SerialPortTransport(port.Port);
                return (work(t,
                    (s, p) => d?.BeginInvoke(() => { FlashProgress = p; FirmwareText = StageText(s, p, restoring); }),
                    l => d?.BeginInvoke(() => LogLine?.Invoke(l))), null);
            }
            catch (UnauthorizedAccessException)
            {
                return (null, "串口被其他程序占用（例如 Arduino IDE 的串口监视器）");
            }
            catch (Exception e)
            {
                return (null, e.Message);
            }
        });
        Busy = false;
        Flashing = false;
        _backupCount = BackupStore.All().Count;
        Raise(nameof(HasBackups));
        Raise(nameof(BackupText));
        if (error is null)
        {
            LogLine?.Invoke(text!);
            Message = text!;
            return true;
        }
        FirmwareText = $"{(restoring ? "还原" : "刷写")}失败：{error}";
        FirmwareMissing = !restoring;
        LogLine?.Invoke($"ESP32 {(restoring ? "还原" : "刷写")}失败：{error}");
        return false;
    }

    public void SkipFlash()
    {
        FirmwareMissing = false;
        FirmwareText = "已跳过刷写，可以稍后在 设置 里完成。";
    }

    // ---- 与固件的串口连接 ----

    /// <summary>程序启动或切换到 ESP32 模式时调用：记住的串口存在就直接连接。</summary>
    public void StartLinkIfPossible()
    {
        if (!UseEsp32 || _linkThread is not null) return;
        if (Selected is null || !SerialPort.GetPortNames().Contains(Selected.Port)) Scan();
        if (Selected is not null) StartLink();
    }

    private void StartLink()
    {
        if (_linkThread is not null || Selected is not { } port) return;
        lock (_linkLock) _linkStop = false;
        var d = System.Windows.Application.Current?.Dispatcher;
        _linkThread = new Thread(() => LinkLoop(port.Port, a => d?.BeginInvoke(a))) { IsBackground = true, Name = "esp32-link" };
        _linkThread.Start();
    }

    private void StopLink()
    {
        lock (_linkLock)
        {
            _linkStop = true;
            _linkPort?.Dispose();
            _linkPort = null;
        }
        _linkThread = null;
        Link = null;
        Iphones = [];
        Hfp = null;
        UpdateCallAudio();
        Call = PhoneCall.Idle;
        Phones = [];
    }

    /// <summary>打开配对窗口（3 分钟），让新的 iPhone 配对</summary>
    public void PairNewIphone() => Send("PAIR");
    /// <summary>删除 ESP32 上保存的所有 iPhone 配对</summary>
    public void ForgetIphones() => Send("UNPAIR");
    /// <summary>删除一台 iPhone 的配对（id 是 PairedIphone.Id）</summary>
    public void ForgetIphone(string id)
    {
        if (System.Text.RegularExpressions.Regex.IsMatch(id, "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")) Send($"UNPAIR {id}");
    }

    // ---- 通话（固件 1.3.0 起）----
    private HfpLink? _hfp;
    private PhoneCall _call = PhoneCall.Idle;
    private IReadOnlyList<PairedPhone> _phones = [];
    private string? _pairCode;
    public HfpLink? Hfp { get => _hfp; private set => Set(ref _hfp, value); }
    public PhoneCall Call { get => _call; private set => Set(ref _call, value); }
    public IReadOnlyList<PairedPhone> Phones { get => _phones; private set => Set(ref _phones, value); }
    public string? PairCode { get => _pairCode; private set => Set(ref _pairCode, value); }
    public bool FirmwareSupportsCalls => FirmwareOk && (UpdateCore.CompareVersions(_firmwareVersion, "1.3.0") ?? -1) >= 0;

    /// <summary>在电脑上接听：声音走电脑</summary>
    public void Answer() { Send("AUDIO PC"); Send("ANSWER"); }
    /// <summary>来电时拒接，通话中/呼出时挂断</summary>
    public void HangUp() => Send("HANGUP");
    public void Dial(string number)
    {
        var n = new string(number.Where(c => "0123456789+*#".Contains(c)).ToArray());
        if (n.Length is > 0 and < 32) { Send("AUDIO PC"); Send($"DIAL {n}"); }
    }
    public void Redial() { Send("AUDIO PC"); Send("REDIAL"); }
    public void SendDtmf(char c) { if ("0123456789*#".Contains(c)) Send($"DTMF {c}"); }
    public void SetAudioToPC(bool on) => Send(on ? "AUDIO PC" : "AUDIO PHONE");
    public void ConnectPhone(string? id = null) => Send(id is null ? "HFP CONNECT" : $"HFP CONNECT {id}");
    private static bool IsAddr(string id) => System.Text.RegularExpressions.Regex.IsMatch(id, "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$");
    /// <summary>设为通话优先手机（null 取消）</summary>
    public void PreferPhone(string? id)
    {
        if (id is null) Send("PREFER NONE");
        else if (IsAddr(id)) Send($"PREFER {id}");
    }
    /// <summary>通话切换到这台手机</summary>
    public void SwitchPhone(string id)
    {
        if (IsAddr(id)) Send($"SWITCH {id}");
    }
    /// <summary>删除一台手机的通话配对</summary>
    public void ForgetPhone(string id)
    {
        if (System.Text.RegularExpressions.Regex.IsMatch(id, "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")) Send($"UNPAIR_BT {id}");
    }

    private IReadOnlyList<PairedIphone> _iphones = [];
    /// <summary>ESP32 上配对过的 iPhone（固件 1.2.2 起逐台上报）</summary>
    public IReadOnlyList<PairedIphone> Iphones { get => _iphones; private set => Set(ref _iphones, value); }
    /// <summary>在 iPhone 上执行通知的操作（正向如接听，负向如清除/拒接）</summary>
    public void Perform(uint uid, bool positive) => Send($"ACT {uid} {(positive ? 0 : 1)}");

    private readonly object _writeLock = new();
    private void Write(SerialPortTransport port, byte[] bytes)
    {
        lock (_writeLock) port.Write(bytes);
    }

    private void Send(string line)
    {
        SerialPortTransport? p;
        lock (_linkLock) p = _linkPort;
        try { if (p is not null) Write(p, Encoding.UTF8.GetBytes(line + "\n")); } catch (Exception) { }
    }

    /// <summary>通话声音（在电脑上播放/采集时不为 null）</summary>
    private volatile CallAudio? _callAudio;
    private ushort _upSeq;

    /// <summary>麦克风帧发给 ESP32（发送线程）</summary>
    private void SendUp(byte[] pcm)
    {
        SerialPortTransport? p;
        lock (_linkLock) p = _linkPort;
        if (p is null) return;
        _upSeq++;
        try { Write(p, SerialDemux.Encode(SerialFrameType.AudioUp, _upSeq, pcm)); } catch (Exception) { }
    }

    private void LinkLoop(string portName, Action<Action> ui)
    {
        var announced = "";
        bool highBaudFailed = false;
        while (true)
        {
            lock (_linkLock) if (_linkStop) return;
            try
            {
                var port = new SerialPortTransport(portName);
                port.SetDtr(false);
                port.SetRts(false);
                lock (_linkLock)
                {
                    if (_linkStop) { port.Dispose(); return; }
                    _linkPort = port;
                }
                Thread.Sleep(300);
                Write(port, Encoding.ASCII.GetBytes("HB?\nSTATE?\nBONDS?\nPHONES?\n"));
                announced = "";
                ui(() => { _linkError = ""; Raise(nameof(LinkText)); });
                var demux = new SerialDemux();
                var lastProbe = DateTime.UtcNow;
                var lastWrite = DateTime.UtcNow;
                var lastValid = DateTime.UtcNow;
                int baud = 115200;
                bool askedHigh = false;
                DateTime? verifyDeadline = null;
                while (true)
                {
                    var bytes = port.Read(TimeSpan.FromMilliseconds(200));
                    var lines = new List<string>();
                    demux.Feed(bytes, lines.Add, f =>
                    {
                        if (f.Type == (byte)SerialFrameType.AudioDown) _callAudio?.Receive(f.Data);
                    });
                    foreach (var line in lines)
                    {
                        if (line.StartsWith("@{", StringComparison.Ordinal) || line.StartsWith("HB-ESP32", StringComparison.Ordinal))
                            lastValid = DateTime.UtcNow;
                        if (line.StartsWith("HB-ESP32 ", StringComparison.Ordinal))
                        {
                            verifyDeadline = null;
                            var v = line.Split(' ').Skip(1).FirstOrDefault() ?? "";
                            // 串口提速：固件 1.3.0 起支持；CH340 在 1M 下最稳（1.5M/2M 持续收发会丢字节）
                            if (!askedHigh && !highBaudFailed && baud == 115200 && (UpdateCore.CompareVersions(v, "1.3.0") ?? -1) >= 0)
                            {
                                askedHigh = true;
                                Write(port, Encoding.ASCII.GetBytes("BAUD 1000000\n"));
                            }
                        }
                        if (line.StartsWith("@{\"t\":\"baud\"", StringComparison.Ordinal))
                        {
                            var i = line.IndexOf("\"value\":", StringComparison.Ordinal);
                            var num = i < 0 ? "" : new string(line[(i + 8)..].TakeWhile(char.IsAsciiDigit).ToArray());
                            if (int.TryParse(num, out var nb))
                            {
                                Thread.Sleep(20);
                                port.SetBaud(nb);
                                baud = nb;
                                Write(port, Encoding.ASCII.GetBytes("HB?\n"));
                                lastWrite = DateTime.UtcNow;
                                verifyDeadline = DateTime.UtcNow.AddSeconds(1.5);
                                ui(() => LogLine?.Invoke($"ESP32 串口提速到 {nb}"));
                            }
                        }
                        if (line.StartsWith("@{\"t\":\"boot\"", StringComparison.Ordinal))
                            ui(() => LogLine?.Invoke($"ESP32 重新启动了：{line[1..]}"));
                        if (Esp32LinkParser.Parse(line) is { } e) ui(() => HandleEvent(e));
                    }
                    var now = DateTime.UtcNow;
                    // 提速后没有回应：USB 芯片不支持这个波特率，停发 4 秒让固件退回 115200
                    if (verifyDeadline is { } d && now > d)
                    {
                        verifyDeadline = null;
                        highBaudFailed = true;
                        port.SetBaud(115200);
                        baud = 115200;
                        ui(() => LogLine?.Invoke("ESP32 串口提速失败，退回 115200"));
                        Thread.Sleep(4000);
                        Write(port, Encoding.ASCII.GetBytes("HB?\nSTATE?\n"));
                    }
                    // 高波特率下每秒一次心跳（固件回 pong）；4 秒没有完整消息多半是 ESP32 重启回到了 115200，重连
                    if (baud != 115200 && now - lastWrite > TimeSpan.FromSeconds(1))
                    {
                        Write(port, Encoding.ASCII.GetBytes("PING\n"));
                        lastWrite = now;
                    }
                    if (baud != 115200 && now - lastValid > TimeSpan.FromSeconds(4))
                    {
                        ui(() => LogLine?.Invoke("ESP32 串口速度对不上了，重新连接"));
                        throw new TimeoutException("串口速度不一致");
                    }
                    if (now - lastProbe > TimeSpan.FromSeconds(30))
                    {
                        lastProbe = now;
                        Write(port, Encoding.ASCII.GetBytes("STATE?\n"));
                    }
                }
            }
            catch (Exception ex)
            {
                bool stopped;
                lock (_linkLock)
                {
                    stopped = _linkStop;
                    _linkPort?.Dispose();
                    _linkPort = null;
                }
                if (stopped) return;
                var text = ex is UnauthorizedAccessException ? "串口被其他程序占用" : ex.Message;
                if (text != announced)
                {
                    announced = text;
                    ui(() =>
                    {
                        Link = null;
                        _linkError = $"ESP32 已断开，正在重试：{text}";
                        Raise(nameof(LinkText));
                    });
                }
                Thread.Sleep(3000);
            }
        }
    }

    /// <summary>根据免提状态开关电脑上的通话声音（界面线程）</summary>
    private void UpdateCallAudio()
    {
        int? want = Hfp is { AudioToPC: true } h ? h.Audio switch { "msbc" => 16000, "cvsd" => 8000, _ => null } : null;
        if (_callAudio is { } cur && cur.SampleRate == want) return;
        _callAudio?.Dispose();
        _callAudio = null;
        if (want is not int sr) return;
        var a = new CallAudio(sr, SendUp, s => System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => LogLine?.Invoke(s)));
        try
        {
            a.Start();
            a.Muted = _muted;
            _callAudio = a;
        }
        catch (Exception e)
        {
            a.Dispose();
            LogLine?.Invoke($"无法打开麦克风或扬声器：{e.Message}");
        }
    }

    private bool _muted;
    /// <summary>静音电脑麦克风</summary>
    public bool Muted
    {
        get => _muted;
        set { Set(ref _muted, value); if (_callAudio is { } a) a.Muted = value; }
    }

    private void HandleEvent(Esp32Event e)
    {
        switch (e)
        {
            case Esp32Event.Hello h:
                SetFound(h.Version);
                break;
            case Esp32Event.Bonds b:
                Iphones = b.List;
                break;
            case Esp32Event.Hfp h:
                Hfp = h.Link;
                UpdateCallAudio();
                break;
            case Esp32Event.Call c:
                Call = c.Info;
                if (!c.Info.IsIdle) PairCode = null;
                break;
            case Esp32Event.Phones ph:
                Phones = ph.List;
                break;
            case Esp32Event.PairCode pc:
                PairCode = pc.Code;
                break;
            case Esp32Event.State s:
                if (s.Link.Ready) _iphoneProblem = "";
                Link = s.Link;
                break;
            case Esp32Event.Error er:
                _iphoneProblem = er.Message;
                Raise(nameof(LinkText));
                LogLine?.Invoke($"ESP32：{er.Message}（{er.Code}）");
                break;
        }
        Event?.Invoke(e);
    }

    // ---- 串口枚举：串口名 + 设备管理器里的名称和 USB VID/PID ----

    [GeneratedRegex(@"\((COM\d+)\)")]
    private static partial Regex ComRegex();

    // USB\VID_1A86&PID_7523\…，FTDI 的串口是 FTDIBUS\VID_0403+PID_6001…
    [GeneratedRegex(@"VID_([0-9A-F]{4})[&+]PID_([0-9A-F]{4})", RegexOptions.IgnoreCase)]
    private static partial Regex VidPidRegex();

    private static List<Esp32Port> ListPorts()
    {
        var info = new Dictionary<string, (string Name, string? Chip)>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT Name, PNPDeviceID FROM Win32_PnPEntity WHERE Name LIKE '%(COM%'");
            foreach (var o in searcher.Get())
            {
                var name = o["Name"] as string ?? "";
                var m = ComRegex().Match(name);
                if (!m.Success) continue;
                var pnp = o["PNPDeviceID"] as string ?? "";
                var vp = VidPidRegex().Match(pnp);
                string? chip = vp.Success
                    ? UsbSerialChip.Name(Convert.ToInt32(vp.Groups[1].Value, 16), Convert.ToInt32(vp.Groups[2].Value, 16))
                    : null;
                info[m.Groups[1].Value] = (name.Replace($"({m.Groups[1].Value})", "").Trim(), chip);
            }
        }
        catch (Exception)
        {
            // WMI 不可用时只列出串口名
        }
        return SerialPort.GetPortNames().Distinct().Select(p =>
            info.TryGetValue(p, out var i) ? new Esp32Port(p, i.Name, i.Chip) : new Esp32Port(p, "串口", null)).ToList();
    }

    /// <summary>插着但设备管理器里报错（28 = 没有安装驱动）的 USB 串口芯片</summary>
    private static List<string> UsbSerialChipsWithoutDriver()
    {
        var result = new List<string>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT PNPDeviceID, ConfigManagerErrorCode FROM Win32_PnPEntity WHERE PNPDeviceID LIKE 'USB\\\\VID_%'");
            foreach (var o in searcher.Get())
            {
                var code = Convert.ToInt32(o["ConfigManagerErrorCode"] ?? 0);
                if (code == 0) continue;
                var vp = VidPidRegex().Match(o["PNPDeviceID"] as string ?? "");
                if (!vp.Success) continue;
                if (UsbSerialChip.Name(Convert.ToInt32(vp.Groups[1].Value, 16), Convert.ToInt32(vp.Groups[2].Value, 16)) is { } chip)
                    result.Add(chip);
            }
        }
        catch (Exception)
        {
            // WMI 不可用时不提示
        }
        return result;
    }

    private static (bool Ok, string Text) Handshake(string portName)
    {
        try
        {
            using var sp = new SerialPort(portName, 115200) { ReadTimeout = 100, WriteTimeout = 1000, NewLine = "\n" };
            sp.Open();
            // 开发板的自动复制电路：拉一下 RTS 让 ESP32 复位，等固件启动
            sp.DtrEnable = false;
            sp.RtsEnable = true;
            Thread.Sleep(100);
            sp.RtsEnable = false;
            Thread.Sleep(1500);
            sp.DiscardInBuffer();
            sp.Write("HB?\n");
            var buf = new StringBuilder();
            var deadline = DateTime.UtcNow.AddSeconds(2);
            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    buf.Append(sp.ReadExisting());
                    var line = buf.ToString().Split('\n').FirstOrDefault(l => l.StartsWith("HB-ESP32", StringComparison.Ordinal));
                    if (line is not null) return (true, line.Trim());
                }
                catch (TimeoutException) { }
                Thread.Sleep(50);
            }
            return (false, buf.Length == 0 ? "设备没有响应，可能还没有刷写 NotiBridge 固件" : "设备有输出，但不是 NotiBridge 固件");
        }
        catch (UnauthorizedAccessException)
        {
            return (false, "串口被其他程序占用（例如 Arduino IDE 的串口监视器）");
        }
        catch (Exception e)
        {
            return (false, $"无法打开串口：{e.Message}");
        }
    }
}

/// <summary>System.IO.Ports 实现的刷写/通信串口。</summary>
internal sealed class SerialPortTransport : IEspSerialTransport, IDisposable
{
    private readonly SerialPort _sp;

    public SerialPortTransport(string port)
    {
        _sp = new SerialPort(port, 115200) { ReadTimeout = 50, WriteTimeout = 5000, Handshake = Handshake.None };
        _sp.Open();
    }

    public void Write(byte[] bytes) => _sp.Write(bytes, 0, bytes.Length);

    public byte[] Read(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (_sp.BytesToRead == 0)
        {
            if (DateTime.UtcNow >= deadline) return [];
            Thread.Sleep(2);
        }
        var buf = new byte[_sp.BytesToRead];
        int n = _sp.Read(buf, 0, buf.Length);
        return buf[..n];
    }

    public void SetDtr(bool on) => _sp.DtrEnable = on;
    public void SetRts(bool on) => _sp.RtsEnable = on;
    public void SetBaud(int baud) => _sp.BaudRate = baud;
    public void FlushInput() => _sp.DiscardInBuffer();
    public void Dispose() => _sp.Dispose();
}
