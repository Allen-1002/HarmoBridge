using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using HarmoBridge.Core;

namespace HarmoBridge.Windows;

public sealed class DeviceItem : ObservableObject
{
    private bool _online;
    private DateTimeOffset? _lastSeen;

    public required string Id { get; init; }
    public required string Name { get; init; }
    public DateTimeOffset PairedAt { get; init; }
    public string Initial => Name.Length > 0 ? Name[..1] : "?";
    public Brush AvatarBrush => new SolidColorBrush(AppIcons.AvatarColor(Id));

    public bool IsOnline
    {
        get => _online;
        set { if (Set(ref _online, value)) Raise(nameof(StatusText)); }
    }

    public DateTimeOffset? LastSeen
    {
        get => _lastSeen;
        set { if (Set(ref _lastSeen, value)) Raise(nameof(StatusText)); }
    }

    public string StatusText => IsOnline ? "在线" :
        LastSeen is { } t ? $"待命 · 最近同步 {t.LocalDateTime:HH:mm}" : "待命（有通知时自动连接）";
}

public sealed class RecordItem : ObservableObject
{
    private bool _showContent;

    public required DateTimeOffset At { get; init; }
    public required string DeviceId { get; init; }
    public required string PhoneName { get; init; }
    public required MirroredNotification Notification { get; init; }
    public required string Result { get; init; }

    public string AppName => string.IsNullOrEmpty(Notification.AppName) ? Notification.BundleName : Notification.AppName;
    public string Initial => AppName.Length > 0 ? AppName[..1] : "?";
    public Brush AvatarBrush => new SolidColorBrush(AppIcons.AvatarColor(string.IsNullOrEmpty(Notification.BundleName) ? AppName : Notification.BundleName));
    public string TimeText => At.LocalDateTime.ToString("HH:mm:ss");

    public string ResultText => Result switch
    {
        "shown" => "已显示",
        "duplicate" => "重复",
        "filtered" => "已过滤",
        "paused" => "已暂停",
        "copied" => "已复制",
        _ => Result,
    };

    public Brush ResultBrush => new SolidColorBrush(Result switch
    {
        "shown" => Color.FromRgb(0x10, 0xB9, 0x81),
        "filtered" => Color.FromRgb(0xF5, 0x9E, 0x0B),
        "copied" => Color.FromRgb(0x3B, 0x82, 0xF6),
        _ => Color.FromRgb(0x9C, 0xA3, 0xAF),
    });

    public bool ShowContent
    {
        get => _showContent;
        set { if (Set(ref _showContent, value)) Raise(nameof(Preview)); }
    }

    /// <summary>默认不显示通知内容，只显示来源；打开“在列表中显示内容”后才显示。</summary>
    public string Preview => ShowContent
        ? $"{Notification.Title}  {Notification.Text}".Trim()
        : $"来自 {PhoneName} · 内容已隐藏";
}

/// <summary>
/// 应用状态（运行在 UI 线程）。与 Mac 端 AppModel 对应：配对窗口、多台手机在线状态、通知显示与过滤、验证码、与手机同步的开关。
/// </summary>
public sealed class AppModel : ObservableObject
{
    private readonly AppSettings _settings;
    private readonly DpapiKeyStore _store = new();
    private readonly PairingWindow _window = new();
    private readonly NotificationDeduper _deduper = new();
    private readonly Notifier _notifier;
    private readonly MdnsAdvertiser _mdns;
    private readonly BridgeServer _server;
    private readonly Dictionary<Guid, string> _connectionDevice = [];
    private readonly DispatcherTimer _pinTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _applyingRemote;

    private string _listening = "未启动";
    private string? _pairingPin;
    private string? _pairingSas;
    private string _pairingRemaining = "";
    private DateTimeOffset? _lastSync;
    private string _lastOtp = "";
    private string _lastOtpApp = "";
    private int _todayOtp;

    /// <summary>ESP32 通话模块（使用方式、硬件检测、固件）</summary>
    public Esp32Manager Esp32 { get; }

    public ObservableCollection<DeviceItem> Devices { get; } = [];
    public ObservableCollection<RecordItem> Records { get; } = [];
    public ObservableCollection<string> Logs { get; } = [];

    public string ComputerName { get; } = Environment.MachineName;
    public int Port => _settings.Port;

    public AppModel()
    {
        _settings = AppSettings.Load();
        Esp32 = new Esp32Manager(_settings);
        _notifier = new Notifier(Log);
        _notifier.Activated += a => Dispatch(() => OnToastActivated(a));
        _mdns = new MdnsAdvertiser(s => Dispatch(() => Log(s)));
        var id = _settings.ComputerId;
        var name = ComputerName;
        _server = new BridgeServer(() => new SessionMachine(_store, _window, id, name, "windows"));
        _server.OnEvent += e => Dispatch(() => Handle(e));
        _pinTimer.Tick += (_, _) => TickPairing();
        ReloadDevices();
        _filterText = FilterTextFromSettings();
    }

    public void Start()
    {
        _server.Start(_settings.Port);
    }

    public void Shutdown()
    {
        _mdns.Dispose();
        _server.Stop();
    }

    private static void Dispatch(Action a)
    {
        var d = Application.Current?.Dispatcher;
        if (d is null) return;
        if (d.CheckAccess()) a();
        else d.BeginInvoke(a);
    }

    // ---------------- 状态 ----------------

    public string Listening
    {
        get => _listening;
        private set => Set(ref _listening, value);
    }

    public string Addresses
    {
        get
        {
            var list = MdnsAdvertiser.LanAddresses();
            return list.Count == 0 ? "未连接网络" : string.Join("\n", list.Select(a => $"{a.Address}  ({a.Interface})"));
        }
    }

    public string PrimaryAddress => MdnsAdvertiser.PrimaryIPv4()?.ToString() ?? "未连接网络";

    public int OnlineCount => Devices.Count(d => d.IsOnline);
    public bool HasDevices => Devices.Count > 0;

    public string Headline
    {
        get
        {
            if (Paused) return "同步已暂停";
            if (Devices.Count == 0) return "还没有配对手机";
            var online = OnlineCount;
            return online > 0 ? $"{online} 台手机在线" : "正在待命";
        }
    }

    public string SubHeadline
    {
        get
        {
            if (Devices.Count == 0) return "点“配对新手机”，在手机 HarmoBridge 里输入配对码";
            var t = _lastSync is { } s ? $"最近同步 {s.LocalDateTime:HH:mm}" : "有通知时手机会自动连接";
            return $"已配对 {Devices.Count} 台手机 · {t}";
        }
    }

    public string TrayText => $"HarmoBridge · {Headline}";

    private IEnumerable<RecordItem> Today => Records.Where(r => r.At.LocalDateTime.Date == DateTime.Today);
    public int TodayShown => Today.Count(r => r.Result == "shown");
    public int TodayFiltered => Today.Count(r => r.Result == "filtered");
    public int TodayOtp => _todayOtp;

    public string LastOtpText => _lastOtp.Length == 0 ? "" : $"{_lastOtp}（来自 {_lastOtpApp}）";
    public bool HasLastOtp => _lastOtp.Length > 0;

    private void RaiseStatus()
    {
        Raise(nameof(OnlineCount));
        Raise(nameof(HasDevices));
        Raise(nameof(Headline));
        Raise(nameof(SubHeadline));
        Raise(nameof(TrayText));
        StatusChanged?.Invoke();
    }

    private void RaiseStats()
    {
        Raise(nameof(TodayShown));
        Raise(nameof(TodayFiltered));
        Raise(nameof(TodayOtp));
        Raise(nameof(HasRecords));
    }

    public bool HasRecords => Records.Count > 0;

    /// <summary>托盘图标需要刷新时触发。</summary>
    public event Action? StatusChanged;

    // ---------------- 同步开关（与手机双向同步） ----------------

    public bool Paused
    {
        get => _settings.Paused;
        set
        {
            if (_settings.Paused == value) return;
            _settings.Paused = value;
            SettingsTouched();
            Raise();
            Raise(nameof(SyncOn));
            RaiseStatus();
        }
    }

    public bool SyncOn
    {
        get => !Paused;
        set => Paused = !value;
    }

    public bool BlockSensitive
    {
        get => _settings.Filter.BlockSensitive;
        set
        {
            if (_settings.Filter.BlockSensitive == value) return;
            _settings.Filter.BlockSensitive = value;
            SettingsTouched();
            Raise();
        }
    }

    public bool CopyOtp
    {
        get => _settings.CopyOtp;
        set
        {
            if (_settings.CopyOtp == value) return;
            _settings.CopyOtp = value;
            SettingsTouched();
            Raise();
        }
    }

    private SharedSettings Shared => new(_settings.Paused, _settings.Filter.BlockSensitive, _settings.CopyOtp, _settings.SettingsUpdatedAt);

    /// <summary>本机改了开关：刷新修改时间并立即推送给所有在线手机。</summary>
    private void SettingsTouched()
    {
        if (!_applyingRemote)
        {
            _settings.SettingsUpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            _server.BroadcastSettings(Shared);
        }
        _settings.Save();
    }

    /// <summary>收到手机的设置：对方更新就采用对方的，回传合并结果，并转发给其他在线手机。</summary>
    private void HandleRemoteSettings(SharedSettings remote, int seq, Guid conn)
    {
        var local = Shared;
        var merged = local.Merged(remote);
        if (merged == remote && remote != local)
        {
            _applyingRemote = true;
            Paused = remote.Paused;
            BlockSensitive = remote.BlockSensitive;
            CopyOtp = remote.CopyOtp;
            _settings.SettingsUpdatedAt = remote.UpdatedAt;
            _settings.Save();
            _applyingRemote = false;
            Log($"已同步手机的设置：同步{(remote.Paused ? "暂停" : "开启")}、敏感过滤{(remote.BlockSensitive ? "开" : "关")}、验证码复制{(remote.CopyOtp ? "开" : "关")}");
            foreach (var other in _server.AuthenticatedConnections.Where(c => c != conn))
                _server.SendSettings(merged, null, other);
        }
        _server.SendSettings(merged, seq, conn);
    }

    // ---------------- 本机设置 ----------------

    public bool ShowContentInList
    {
        get => _settings.ShowContentInList;
        set
        {
            if (_settings.ShowContentInList == value) return;
            _settings.ShowContentInList = value;
            _settings.Save();
            foreach (var r in Records) r.ShowContent = value;
            Raise();
        }
    }

    public bool AutoStartEnabled
    {
        get => AutoStart.IsEnabled;
        set
        {
            try
            {
                AutoStart.Set(value);
                Log(value ? "已开启开机启动" : "已关闭开机启动");
            }
            catch (Exception e)
            {
                Log($"设置开机启动失败：{e.Message}");
            }
            Raise();
        }
    }

    public bool IsInstalled => Installer.IsRunningInstalled;
    public bool IsPortable => !Installer.IsRunningInstalled;
    public string InstallText => Installer.IsRunningInstalled
        ? $"已安装到 {Installer.InstallDir}，可以在“设置 > 应用 > 已安装的应用”中卸载。"
        : "当前以免安装（绿色版）方式运行，没有快捷方式，也不会出现在“已安装的应用”里。";

    public bool Onboarded
    {
        get => _settings.Onboarded;
        set
        {
            _settings.Onboarded = value;
            _settings.Save();
            Raise();
        }
    }

    // ---------------- 过滤规则 ----------------

    public bool WhitelistOnly
    {
        get => _settings.Filter.Mode == SyncFilter.FilterMode.WhitelistOnly;
        set
        {
            _settings.Filter.Mode = value ? SyncFilter.FilterMode.WhitelistOnly : SyncFilter.FilterMode.AllExceptBlacklist;
            _settings.Save();
            Raise();
        }
    }

    public sealed class FilterText
    {
        public string Blacklist { get; set; } = "";
        public string Whitelist { get; set; } = "";
        public string Keywords { get; set; } = "";
    }

    private FilterText _filterText;
    public FilterText FilterEdit => _filterText;

    private FilterText FilterTextFromSettings() => new()
    {
        Blacklist = string.Join(Environment.NewLine, _settings.Filter.Blacklist.Order()),
        Whitelist = string.Join(Environment.NewLine, _settings.Filter.Whitelist.Order()),
        Keywords = string.Join(Environment.NewLine, _settings.Filter.SensitiveKeywords),
    };

    private static IEnumerable<string> Lines(string s) =>
        s.Split(['\r', '\n', ',', '，'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct();

    public void ApplyFilterText()
    {
        _settings.Filter.Blacklist = [.. Lines(_filterText.Blacklist)];
        _settings.Filter.Whitelist = [.. Lines(_filterText.Whitelist)];
        _settings.Filter.SensitiveKeywords = [.. Lines(_filterText.Keywords)];
        _settings.Save();
        Log($"已保存过滤规则：黑名单 {_settings.Filter.Blacklist.Count} 个，白名单 {_settings.Filter.Whitelist.Count} 个，关键词 {_settings.Filter.SensitiveKeywords.Count} 个");
    }

    public void ResetKeywords()
    {
        _settings.Filter.SensitiveKeywords = [.. SyncFilter.DefaultKeywords];
        _settings.Save();
        _filterText = FilterTextFromSettings();
        Raise(nameof(FilterEdit));
    }

    public void BlockApp(RecordItem r)
    {
        var bundle = r.Notification.BundleName;
        if (bundle.Length == 0) return;
        _settings.Filter.Blacklist.Add(bundle);
        _settings.Save();
        _filterText = FilterTextFromSettings();
        Raise(nameof(FilterEdit));
        Log($"已把 {r.AppName}（{bundle}）加入黑名单");
    }

    // ---------------- 配对 ----------------

    public string? PairingPin
    {
        get => _pairingPin;
        private set { if (Set(ref _pairingPin, value)) Raise(nameof(IsPairing)); }
    }

    public string? PairingSas
    {
        get => _pairingSas;
        private set { if (Set(ref _pairingSas, value)) Raise(nameof(HasSas)); }
    }

    public bool IsPairing => _pairingPin is not null;
    public bool HasSas => _pairingSas is not null;

    public string PairingRemaining
    {
        get => _pairingRemaining;
        private set => Set(ref _pairingRemaining, value);
    }

    public void OpenPairing()
    {
        _window.Open();
        PairingPin = _window.ActivePin();
        PairingSas = null;
        TickPairing();
        _pinTimer.Start();
        Log("已开启配对，配对码 2 分钟内有效");
    }

    public void CancelPairing()
    {
        _window.Close();
        PairingPin = null;
        PairingSas = null;
        _pinTimer.Stop();
    }

    private void TickPairing()
    {
        var pin = _window.ActivePin();
        if (pin is null)
        {
            if (PairingPin is not null) Log("配对窗口已关闭");
            CancelPairing();
            return;
        }
        PairingPin = pin; // 输错 3 次会作废
        var left = (_window.ExpiresAt ?? DateTimeOffset.UtcNow) - DateTimeOffset.UtcNow;
        PairingRemaining = $"{(int)left.TotalMinutes}:{left.Seconds:D2} 后失效";
    }

    public void Unpair(DeviceItem d)
    {
        _store.Remove(d.Id);
        _server.Disconnect(d.Id);
        ReloadDevices();
        Log($"已取消配对：{d.Name}");
    }

    private void ReloadDevices()
    {
        var online = Devices.ToDictionary(d => d.Id, d => (d.IsOnline, d.LastSeen));
        Devices.Clear();
        foreach (var d in _store.Devices().OrderBy(d => d.PairedAt))
        {
            var item = new DeviceItem { Id = d.Id, Name = d.Name, PairedAt = d.PairedAt };
            if (online.TryGetValue(d.Id, out var st))
            {
                item.IsOnline = st.IsOnline;
                item.LastSeen = st.LastSeen;
            }
            Devices.Add(item);
        }
        RaiseStatus();
    }

    private DeviceItem? Device(string id) => Devices.FirstOrDefault(d => d.Id == id);
    private string DeviceName(string id) => Device(id)?.Name ?? id[..Math.Min(8, id.Length)];

    // ---------------- 事件处理 ----------------

    private void Handle(BridgeServer.Event e)
    {
        switch (e)
        {
            case BridgeServer.Event.Listening l:
                Listening = $"监听中 :{l.Port}";
                Log($"WebSocket 服务已启动，端口 {l.Port}");
                _mdns.Register($"HarmoBridge-{ComputerName}", _settings.ComputerId, l.Port);
                Raise(nameof(Addresses));
                Raise(nameof(PrimaryAddress));
                break;
            case BridgeServer.Event.Stopped s:
                Listening = s.Reason;
                Log($"服务状态：{s.Reason}");
                break;
            case BridgeServer.Event.Disconnected d:
                _connectionDevice.Remove(d.Connection);
                if (d.WasAuthenticated && d.DeviceId is { } dev && !_connectionDevice.ContainsValue(dev))
                {
                    if (Device(dev) is { } item) item.IsOnline = false;
                    Log($"手机已断开：{DeviceName(dev)}");
                    RaiseStatus();
                }
                break;
            case BridgeServer.Event.Output o:
                HandleOutput(o.Value, o.Connection);
                break;
        }
    }

    private void HandleOutput(SessionOutput o, Guid conn)
    {
        switch (o)
        {
            case SessionOutput.Log l:
                Log(l.Text);
                break;
            case SessionOutput.PairingStarted p:
                PairingSas = p.Sas;
                Log($"手机发起配对，请核对两端校验码：{p.Sas}");
                break;
            case SessionOutput.Paired p:
                CancelPairing();
                ReloadDevices();
                Log($"配对成功：{p.Name}（{p.DeviceId[..Math.Min(8, p.DeviceId.Length)]}…）");
                _notifier.ShowLocal("配对成功", $"{p.Name} 已与这台电脑配对");
                break;
            case SessionOutput.Authenticated a:
                _connectionDevice[conn] = a.DeviceId;
                if (Device(a.DeviceId) is { } item)
                {
                    item.IsOnline = true;
                    item.LastSeen = DateTimeOffset.Now;
                }
                _lastSync = DateTimeOffset.Now;
                Log($"手机已认证上线：{DeviceName(a.DeviceId)}");
                RaiseStatus();
                break;
            case SessionOutput.Ping p:
                Touch(conn);
                _server.Ack(p.Seq, "pong", conn);
                break;
            case SessionOutput.Notify n:
                Touch(conn);
                _server.Ack(n.Seq, Present(n.Notification, conn), conn);
                break;
            case SessionOutput.Settings s:
                Touch(conn);
                HandleRemoteSettings(s.Value, s.Seq, conn);
                break;
            case SessionOutput.Otp otp:
                Touch(conn);
                _server.Ack(otp.Seq, HandleOtp(otp.Code), conn);
                break;
            case SessionOutput.Cancel c:
                Touch(conn);
                if (_connectionDevice.TryGetValue(conn, out var dev))
                {
                    _notifier.Remove(dev, c.Ids);
                    foreach (var id in c.Ids) _deduper.Remove(dev + "|" + id);
                }
                Log($"手机撤销通知 {c.Ids.Length} 条");
                _server.Ack(c.Seq, "removed", conn);
                break;
        }
    }

    private void Touch(Guid conn)
    {
        _lastSync = DateTimeOffset.Now;
        if (_connectionDevice.TryGetValue(conn, out var d) && Device(d) is { } item) item.LastSeen = DateTimeOffset.Now;
        Raise(nameof(SubHeadline));
    }

    private string Present(MirroredNotification n, Guid conn)
    {
        var dev = _connectionDevice.GetValueOrDefault(conn, "");
        string result;
        if (Paused)
        {
            result = "paused";
        }
        else if (_settings.Filter.Decide(n.BundleName, n.Title, n.Text) is { } reason)
        {
            result = "filtered";
            Log($"已过滤 {n.BundleName}：{reason}");
        }
        else
        {
            // 按“手机 + 通知 id”去重：不同手机的通知 id 可能相同
            switch (_deduper.Check(dev + "|" + n.Id, n.Title, n.Text))
            {
                case NotificationDeduper.Result.Duplicate:
                    result = "duplicate";
                    break;
                default:
                    _notifier.Show(n, dev, DeviceName(dev), Devices.Count > 1);
                    result = "shown";
                    break;
            }
        }
        Records.Insert(0, new RecordItem
        {
            At = DateTimeOffset.Now, DeviceId = dev, PhoneName = DeviceName(dev), Notification = n, Result = result,
            ShowContent = ShowContentInList,
        });
        while (Records.Count > 200) Records.RemoveAt(Records.Count - 1);
        RaiseStats();
        return result;
    }

    // ---------------- 验证码 ----------------

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    private string HandleOtp(OtpCode o)
    {
        if (Paused) return "paused";
        if (_settings.Filter.Blacklist.Contains(o.BundleName)) return "filtered";
        if (!CopyOtp) return "filtered";
        if (!CopyToClipboard(o.Code, sensitive: true)) return "filtered";
        var seq = GetClipboardSequenceNumber();
        _lastOtp = o.Code;
        _lastOtpApp = o.AppName;
        _todayOtp++;
        Raise(nameof(LastOtpText));
        Raise(nameof(HasLastOtp));
        RaiseStats();
        _notifier.ShowOtp(o.Code, o.AppName);
        Log($"验证码已复制到剪贴板（来自 {o.AppName}，{o.Code.Length} 位）");
        // 2 分钟后若剪贴板没被改过，就清除
        var t = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            try
            {
                if (GetClipboardSequenceNumber() == seq) Clipboard.Clear();
            }
            catch (Exception)
            {
                // 剪贴板被其他程序占用时忽略
            }
        };
        t.Start();
        return "copied";
    }

    /// <summary>
    /// 复制文本。验证码标记为不进入“剪贴板历史(Win+V)”和云剪贴板。
    /// </summary>
    public bool CopyToClipboard(string text, bool sensitive)
    {
        for (var i = 0; i < 5; i++)
        {
            try
            {
                var data = new DataObject();
                data.SetText(text);
                if (sensitive)
                {
                    data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream([0, 0, 0, 0]));
                    data.SetData("CanIncludeInClipboardHistory", new MemoryStream([0, 0, 0, 0]));
                    data.SetData("CanUploadToCloudClipboard", new MemoryStream([0, 0, 0, 0]));
                }
                Clipboard.SetDataObject(data, true);
                return true;
            }
            catch (COMException)
            {
                Thread.Sleep(50); // 剪贴板被占用，稍后重试
            }
        }
        Log("复制失败：剪贴板被其他程序占用");
        return false;
    }

    public void CopyLastOtp()
    {
        if (_lastOtp.Length > 0) CopyToClipboard(_lastOtp, true);
    }

    private void OnToastActivated(string action)
    {
        if (action.StartsWith("copy:", StringComparison.Ordinal))
            CopyToClipboard(action[5..], true);
        else
            ShowWindowRequested?.Invoke();
    }

    public event Action? ShowWindowRequested;

    // ---------------- 其他 ----------------

    public void SendLocalTestNotification()
    {
        _notifier.ShowLocal("Windows 通知通道正常", "这条通知由电脑本机生成，不来自手机。");
        Log("已发送本机自检通知（不经过手机）");
    }

    public static void OpenBluetoothSettings() => OpenUri("ms-settings:bluetooth");
    public static void OpenNotificationSettings() => OpenUri("ms-settings:notifications");
    public static void OpenFirewallSettings() => OpenUri("ms-settings:windowsdefender");
    public static void OpenNetworkSettings() => OpenUri("ms-settings:network-status");

    public static void OpenUri(string uri)
    {
        try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); }
        catch (Exception) { }
    }

    public void ClearRecords()
    {
        Records.Clear();
        RaiseStats();
    }

    public void Log(string text)
    {
        // 日志不写入通知正文
        Logs.Insert(0, $"{DateTime.Now:HH:mm:ss}  {text}");
        while (Logs.Count > 300) Logs.RemoveAt(Logs.Count - 1);
        Debug.WriteLine("HarmoBridge: " + text);
    }
}
