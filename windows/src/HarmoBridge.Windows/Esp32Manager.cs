using System.IO.Ports;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;

namespace HarmoBridge.Windows;

/// <summary>一个可能是 ESP32 的 USB 串口。</summary>
public sealed record Esp32Port(string Port, string Name, string? Chip)
{
    public bool IsLikelyEsp32 => Chip is not null;
    public string Label => Chip is null ? $"{Port} · {Name}" : $"{Port} · {Name}（{Chip}）";
    public override string ToString() => Label;
}

/// <summary>
/// ESP32 通话模块：检测已连接的硬件、检测固件、刷写固件（入口），与 Mac 端 Esp32Manager 一致。
/// 固件握手：以 115200 波特率发送 "HB?\n"，HarmoBridge 固件回复 "HB-ESP32 &lt;版本&gt; ..."。固件尚未发布，刷写暂时只提示。
/// </summary>
public sealed partial class Esp32Manager : ObservableObject
{
    /// <summary>固件是否已经随程序发布（发布后放进程序资源，并改为 true）</summary>
    public const bool FirmwareAvailable = false;

    private readonly AppSettings _settings;
    private IReadOnlyList<Esp32Port> _ports = [];
    private Esp32Port? _selected;
    private string _message = "";
    private string _firmwareText = "";
    private bool _busy;
    private bool _firmwareMissing;
    private bool _firmwareOk;

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
        }
    }

    public bool UseSoftware
    {
        get => !UseEsp32;
        set => UseEsp32 = !value;
    }

    public IReadOnlyList<Esp32Port> Ports { get => _ports; private set { Set(ref _ports, value); Raise(nameof(HasPorts)); } }
    public bool HasPorts => _ports.Count > 0;
    public Esp32Port? Selected { get => _selected; set => Set(ref _selected, value); }
    public string Message { get => _message; private set => Set(ref _message, value); }
    public string FirmwareText { get => _firmwareText; private set => Set(ref _firmwareText, value); }
    public bool Busy { get => _busy; private set { Set(ref _busy, value); Raise(nameof(NotBusy)); } }
    public bool NotBusy => !_busy;
    public bool FirmwareMissing { get => _firmwareMissing; private set => Set(ref _firmwareMissing, value); }
    public bool FirmwareOk { get => _firmwareOk; private set => Set(ref _firmwareOk, value); }
    public bool Scanned { get; private set; }

    public void Scan()
    {
        Scanned = true;
        FirmwareText = "";
        FirmwareMissing = false;
        FirmwareOk = false;
        var list = ListPorts().OrderBy(p => p.IsLikelyEsp32 ? 0 : 1).ThenBy(p => p.Port).ToList();
        Ports = list;
        Selected = list.FirstOrDefault();
        Message = list.Count == 0
            ? "没有找到。请用支持数据传输的 USB 线连接 ESP32；CH340 / CP210x 芯片的板子可能需要先安装驱动。"
            : list.Any(p => p.IsLikelyEsp32) ? "已找到 ESP32 模块" : "找到串口，但无法确认是 ESP32";
    }

    /// <summary>检测固件：发送握手，2 秒内收到 HarmoBridge 固件的回复即成功。</summary>
    public async Task CheckFirmwareAsync()
    {
        if (Selected is not { } port) return;
        Busy = true;
        FirmwareText = "正在检测…";
        FirmwareMissing = false;
        FirmwareOk = false;
        var (ok, text) = await Task.Run(() => Handshake(port.Port));
        Busy = false;
        if (ok)
        {
            var version = text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).FirstOrDefault() ?? "?";
            FirmwareText = $"已检测到 HarmoBridge 固件 {version}，可以使用通话功能";
            FirmwareOk = true;
        }
        else
        {
            FirmwareText = $"未检测到固件：{text}";
            FirmwareMissing = true;
        }
    }

    /// <summary>刷写固件（入口）。固件发布前只提示。</summary>
    public void Flash()
    {
        if (!FirmwareAvailable)
        {
            Message = "ESP32 通话固件尚未发布，暂时无法刷写。固件发布后更新 HarmoBridge，在这里一键刷写即可。";
        }
    }

    public void SkipFlash()
    {
        FirmwareMissing = false;
        FirmwareText = "已跳过刷写，可以稍后在 设置 里完成。";
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
            return (false, buf.Length == 0 ? "设备没有响应，可能还没有刷写 HarmoBridge 固件" : "设备有输出，但不是 HarmoBridge 固件");
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
