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
    private const string FirmwareResource = "notibridge-esp32.bin";

    public static bool FirmwareAvailable => typeof(Esp32Manager).Assembly.GetManifestResourceInfo(FirmwareResource) is not null;
    public static string BundledVersion => typeof(Esp32Manager).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "?";

    private readonly AppSettings _settings;
    private IReadOnlyList<Esp32Port> _ports = [];
    private Esp32Port? _selected;
    private string _message = "";
    private string _firmwareText = "";
    private bool _busy;
    private bool _firmwareMissing;
    private bool _firmwareOk;
    private string? _firmwareVersion;
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

    public Esp32Manager(AppSettings settings) => _settings = settings;

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
    public bool NeedsFirmwareUpdate => FirmwareOk && FirmwareAvailable && _firmwareVersion != BundledVersion;
    public string UpdateFirmwareText => $"NotiBridge 附带了新固件 {BundledVersion}";

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
    public string LinkText => _link?.Label ?? (_linkError.Length > 0 ? _linkError : "正在连接 ESP32…");
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
        Selected = list.FirstOrDefault(p => p.Port == _settings.Esp32Port) ?? list.FirstOrDefault();
        Message = list.Count == 0
            ? "没有找到。请用支持数据传输的 USB 线连接 ESP32；CH340 / CP210x 芯片的板子可能需要先安装驱动。"
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
        FirmwareText = $"已检测到 NotiBridge 固件 {version}";
        FirmwareMissing = false;
        FirmwareOk = true;
    }

    /// <summary>刷写随程序打包的固件（ESP32 ROM 下载协议，不需要 esptool）。</summary>
    public async void Flash()
    {
        if (Selected is not { } port) return;
        using var stream = typeof(Esp32Manager).Assembly.GetManifestResourceStream(FirmwareResource);
        if (stream is null)
        {
            Message = "这个版本的 NotiBridge 没有附带 ESP32 固件。";
            return;
        }
        var image = new byte[stream.Length];
        stream.ReadExactly(image);
        StopLink();
        Busy = true;
        Flashing = true;
        FirmwareMissing = false;
        FirmwareOk = false;
        FlashProgress = 0;
        FirmwareText = "正在进入下载模式…（不要拔掉板子）";
        LogLine?.Invoke($"开始刷写 ESP32 固件 {BundledVersion}（{image.Length / 1024} KB）");
        var d = System.Windows.Application.Current?.Dispatcher;
        string? error = await Task.Run(() =>
        {
            try
            {
                using var t = new SerialPortTransport(port.Port);
                var f = new EspFlasher(t);
                f.Stage += (s, p) => d?.BeginInvoke(() =>
                {
                    FlashProgress = p;
                    FirmwareText = s switch
                    {
                        EspFlashStage.Connecting => "正在进入下载模式…",
                        EspFlashStage.Erasing => "正在擦除…",
                        EspFlashStage.Writing => $"正在写入 {(int)(p * 100)}%",
                        EspFlashStage.Verifying => "正在校验…",
                        _ => "完成",
                    } + "（不要拔掉板子）";
                });
                f.Flash(image, FirmwareOffset);
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                return "串口被其他程序占用（例如 Arduino IDE 的串口监视器）";
            }
            catch (Exception e)
            {
                return e.Message;
            }
        });
        Busy = false;
        Flashing = false;
        if (error is null)
        {
            LogLine?.Invoke("ESP32 固件刷写完成");
            await Task.Delay(1500);
            await CheckFirmwareAsync();
        }
        else
        {
            FirmwareText = $"刷写失败：{error}";
            FirmwareMissing = true;
            LogLine?.Invoke($"ESP32 刷写失败：{error}");
        }
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
    }

    /// <summary>打开配对窗口（3 分钟），让新的 iPhone 配对</summary>
    public void PairNewIphone() => Send("PAIR");
    /// <summary>删除 ESP32 上保存的所有 iPhone 配对</summary>
    public void ForgetIphones() => Send("UNPAIR");
    /// <summary>在 iPhone 上执行通知的操作（正向如接听，负向如清除/拒接）</summary>
    public void Perform(uint uid, bool positive) => Send($"ACT {uid} {(positive ? 0 : 1)}");

    private void Send(string line)
    {
        SerialPortTransport? p;
        lock (_linkLock) p = _linkPort;
        try { p?.Write(Encoding.UTF8.GetBytes(line + "\n")); } catch (Exception) { }
    }

    private void LinkLoop(string portName, Action<Action> ui)
    {
        var announced = "";
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
                port.Write(Encoding.ASCII.GetBytes("HB?\nSTATE?\n"));
                announced = "";
                ui(() => { _linkError = ""; Raise(nameof(LinkText)); });
                var splitter = new LineSplitter();
                var lastProbe = DateTime.UtcNow;
                while (true)
                {
                    var bytes = port.Read(TimeSpan.FromMilliseconds(500));
                    foreach (var line in splitter.Feed(bytes))
                    {
                        if (Esp32LinkParser.Parse(line) is { } e) ui(() => HandleEvent(e));
                    }
                    if (DateTime.UtcNow - lastProbe > TimeSpan.FromSeconds(30))
                    {
                        lastProbe = DateTime.UtcNow;
                        port.Write(Encoding.ASCII.GetBytes("STATE?\n"));
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

    private void HandleEvent(Esp32Event e)
    {
        switch (e)
        {
            case Esp32Event.Hello h:
                SetFound(h.Version);
                break;
            case Esp32Event.State s:
                Link = s.Link;
                break;
            case Esp32Event.Error er:
                LogLine?.Invoke($"ESP32：{er.Message}（{er.Code}）");
                break;
        }
        Event?.Invoke(e);
    }

    // ---- 串口枚举：串口名 + 设备管理器里的名称和 USB VID/PID ----

    [GeneratedRegex(@"\((COM\d+)\)")]
    private static partial Regex ComRegex();

    [GeneratedRegex(@"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase)]
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
                string? chip = null;
                if (vp.Success)
                {
                    var vid = vp.Groups[1].Value.ToUpperInvariant();
                    var pid = vp.Groups[2].Value.ToUpperInvariant();
                    chip = vid switch
                    {
                        "10C4" => "CP210x",
                        "1A86" => pid == "55D4" ? "CH9102" : "CH340",
                        "0403" => "FTDI",
                        "303A" => "ESP32 原生 USB",
                        _ => null,
                    };
                }
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
