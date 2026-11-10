using System.Collections.Specialized;
using System.ComponentModel;
using System.Reflection;
using NotiBridge.Core;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace NotiBridge.Windows;

public partial class MainWindow : Window
{
    // 侧边栏页面序号
    private const int NavOverview = 0, NavDevices = 1, NavEsp = 2, NavRecords = 3;
    private readonly AppModel _model;
    private FrameworkElement[] _pages = [];
    private FrameworkElement[] _obPages = [];
    private int _obIndex;
    /// <summary>引导里“你用什么手机”：iphone / android / both，没选时为空</summary>
    private string _phones = "";

    public MainWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        DataContext = model;
        _pages = [Page0, Page2, PageEsp, Page1, Page3, Page5];
        _obPages = [Ob0, ObPhones, ObCalls, Ob1, Ob2, ObEsp, Ob4, Ob5];
        _iphoneTimer.Tick += (_, _) => RefreshIphoneFlow();
        VersionText.Text = $"NotiBridge for Windows {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3)} · 与 Mac 版、手机端使用同一套加密协议";

        model.Records.CollectionChanged += OnRecordsChanged;
        model.Devices.CollectionChanged += OnDevicesChanged;
        model.PropertyChanged += OnModelChanged;
        model.Esp32.PropertyChanged += OnEspChanged;
        model.AddDeviceRequested += OnAddDeviceRequested;
        EspPagePanel.AddIphoneRequested += () =>
        {
            Go(NavDevices);
            StartAddFlow(AddKind.Iphone);
        };
        OnRecordsChanged(null, null);
        OnDevicesChanged(null, null);
        LoadFilterText();
        UpdatePairIdle();
        Nav.SelectedIndex = 0;

        if (model.Onboarded) ShowMainUi();
        else ShowOnboarding();
    }

    // 关闭窗口只是关掉界面，程序继续在托盘运行（App 使用 OnExplicitShutdown）

    protected override void OnClosed(EventArgs e)
    {
        _model.Records.CollectionChanged -= OnRecordsChanged;
        _model.Devices.CollectionChanged -= OnDevicesChanged;
        _model.PropertyChanged -= OnModelChanged;
        _model.Esp32.PropertyChanged -= OnEspChanged;
        _model.AddDeviceRequested -= OnAddDeviceRequested;
        _iphoneTimer.Stop();
        base.OnClosed(e);
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.IsPairing):
                UpdatePairIdle();
                break;
            case nameof(AppModel.FilterEdit):
                LoadFilterText();
                break;
        }
    }

    private void UpdatePairIdle() => PairIdle.Visibility = _model.IsPairing ? Visibility.Collapsed : Visibility.Visible;

    private void OnRecordsChanged(object? sender, NotifyCollectionChangedEventArgs? e)
    {
        RecentList.ItemsSource = _model.Records.Take(6).ToList();
        NoRecordsHint.Visibility = _model.Records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnDevicesChanged(object? sender, NotifyCollectionChangedEventArgs? e)
    {
        RefreshDeviceList();
        RefreshPhoneFlow();
    }

    private void OnEspChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(() =>
    {
        RefreshDeviceList();
        RefreshIphoneFlow();
    });

    /// <summary>设备列表：手机 App（绑定 Devices）+ 经 ESP32 的 iPhone</summary>
    private void RefreshDeviceList()
    {
        IReadOnlyList<PairedIphone> iphones = _model.Esp32.UseEsp32 ? _model.Esp32.Iphones : [];
        IphoneDevices.ItemsSource = iphones.Select(p => new IphoneRow(p.Id, IphoneDisplay.Name(p), "经 ESP32 · " + IphoneDisplay.Status(p),
            p.AncsReady ? "通知 ✓  ·  通话 即将支持" : "通知 未就绪  ·  通话 即将支持")).ToList();
        NoDevicesHint.Visibility = _model.HasDevices ? Visibility.Collapsed : Visibility.Visible;
        DevicesFooter.Text = _model.Esp32.UseEsp32
            ? "安卓、鸿蒙手机通过局域网同步通知；iPhone 通过 ESP32 模块同步通知。通话功能即将支持。手机 App 不在前台时由系统按需连接转发，所以“待命”不等于收不到通知。"
            : "纯软件模式支持安卓、鸿蒙手机的通知。想同步 iPhone 通知或在电脑上接打电话，请在“ESP32 模块”里启用 ESP32 模式。";
        AddIphoneHint.Text = _model.Esp32.UseEsp32
            ? "不用装 App：iPhone 在蓝牙设置里和 ESP32 模块配对。"
            : "需要 ESP32 模块。当前是纯软件模式，选择后可以启用 ESP32 模式。";
        // 引导“添加设备”这一步：添加完成后按钮立即从“稍后添加”变成“下一步”
        if (Onboarding.Visibility == Visibility.Visible && _obPages.Length > 0) UpdateObNext();
    }

    // ---------------- 添加设备 ----------------

    private enum AddKind { Phone, Iphone }

    private sealed record IphoneRow(string Id, string Name, string Status, string Caps);

    private readonly DispatcherTimer _iphoneTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private HashSet<string> _startPhoneIds = [];
    private HashSet<string> _startIphoneIds = [];
    private DateTime? _iphoneDeadline;

    private void OnAddDeviceRequested()
    {
        if (Onboarding.Visibility == Visibility.Visible) return;
        Go(NavDevices);
        ResetAddDevice();
    }

    /// <summary>回到“选择设备类型”，并取消进行中的配对</summary>
    private void ResetAddDevice()
    {
        _model.CancelPairing();
        _iphoneDeadline = null;
        _iphoneTimer.Stop();
        AddChooser.Visibility = Visibility.Visible;
        AddPhoneFlow.Visibility = Visibility.Collapsed;
        AddIphoneFlow.Visibility = Visibility.Collapsed;
    }

    private void StartAddFlow(AddKind kind)
    {
        ResetAddDevice();
        AddChooser.Visibility = Visibility.Collapsed;
        if (kind == AddKind.Phone)
        {
            AddPhoneFlow.Visibility = Visibility.Visible;
            _startPhoneIds = _model.Devices.Select(d => d.Id).ToHashSet();
            _model.OpenPairing();
            RefreshPhoneFlow();
        }
        else
        {
            AddIphoneFlow.Visibility = Visibility.Visible;
            StartIphonePairingIfReady();
            _iphoneTimer.Start();
            RefreshIphoneFlow();
        }
    }

    private void RefreshPhoneFlow()
    {
        if (AddPhoneFlow.Visibility != Visibility.Visible) return;
        var added = _model.Devices.FirstOrDefault(d => !_startPhoneIds.Contains(d.Id));
        AddPhoneDone.Text = added is null ? "" : $"✓ 已添加：{added.Name}。这台手机的通知会同步到这台电脑。";
        AddPhoneDone.Visibility = added is null ? Visibility.Collapsed : Visibility.Visible;
        AddPhoneSteps.Visibility = added is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private bool EspReady => _model.Esp32.UseEsp32 && _model.Esp32.Link is not null;

    private void StartIphonePairingIfReady()
    {
        if (!EspReady) return;
        _startIphoneIds = _model.Esp32.Iphones.Select(p => p.Id).ToHashSet();
        _model.Esp32.PairNewIphone();
        _iphoneDeadline = DateTime.Now.AddMinutes(3);
    }

    private enum IphoneAction { None, EnableEsp32, OpenEsp32, Start }
    private IphoneAction _iphoneAction;

    private void RefreshIphoneFlow()
    {
        if (AddIphoneFlow.Visibility != Visibility.Visible) return;
        var esp = _model.Esp32;
        var added = esp.Iphones.FirstOrDefault(p => !_startIphoneIds.Contains(p.Id));
        var steps = false;
        string title, text, action = "";
        _iphoneAction = IphoneAction.None;
        if (!esp.UseEsp32)
        {
            title = "iPhone 需要 ESP32 模式";
            text = "iPhone 不允许第三方 App 读取通知，NotiBridge 通过一块 ESP32 模块以蓝牙配件的身份接收 iPhone 通知，再经 USB 转到电脑。";
            (action, _iphoneAction) = ("启用 ESP32 模式", IphoneAction.EnableEsp32);
        }
        else if (esp.Link is null)
        {
            title = "ESP32 模块还没准备好";
            text = esp.FirmwareOk ? esp.LinkText : "请先用 USB 线连接 ESP32 模块，并完成固件刷写。";
            if (Onboarding.Visibility != Visibility.Visible) (action, _iphoneAction) = ("去 ESP32 模块页面", IphoneAction.OpenEsp32);
        }
        else if (added is { AncsReady: true })
        {
            title = $"✓ 已添加：{IphoneDisplay.Name(added)}";
            text = "这台 iPhone 的通知会经 ESP32 同步到这台电脑。";
            _iphoneTimer.Stop();
        }
        else if (_iphoneDeadline is null)
        {
            title = "ESP32 已就绪";
            text = "点下面的按钮打开 ESP32 的配对窗口（3 分钟）。";
            (action, _iphoneAction) = ("开始配对 iPhone", IphoneAction.Start);
        }
        else
        {
            steps = true;
            var left = (int)(_iphoneDeadline.Value - DateTime.Now).TotalSeconds;
            if (left > 0)
            {
                title = added is null ? "等待 iPhone 配对…" : $"已配对“{IphoneDisplay.Name(added)}”，等待 iPhone 允许共享通知…";
                text = $"配对窗口剩余 {left / 60}:{left % 60:00}";
            }
            else
            {
                title = "配对窗口已关闭";
                text = "没有收到 iPhone 的配对请求。";
                (action, _iphoneAction) = ("重新开始", IphoneAction.Start);
            }
            if (!esp.LinkText.StartsWith("iPhone 已连接") && esp.LinkText.Contains('：')) text += "\n" + esp.LinkText;
        }
        IphoneFlowTitle.Text = title;
        IphoneFlowText.Text = text;
        IphoneFlowSteps.Visibility = steps ? Visibility.Visible : Visibility.Collapsed;
        IphoneFlowAction.Content = action;
        IphoneFlowAction.Visibility = action.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnIphoneAction(object sender, RoutedEventArgs e)
    {
        switch (_iphoneAction)
        {
            case IphoneAction.EnableEsp32:
                _model.Esp32.UseEsp32 = true;
                break;
            case IphoneAction.OpenEsp32:
                Go(NavEsp);
                break;
            case IphoneAction.Start:
                StartIphonePairingIfReady();
                break;
        }
        RefreshIphoneFlow();
    }

    private void OnAddPhone(object sender, RoutedEventArgs e) => StartAddFlow(AddKind.Phone);
    private void OnAddIphone(object sender, RoutedEventArgs e) => StartAddFlow(AddKind.Iphone);
    private void OnAddBack(object sender, RoutedEventArgs e) => ResetAddDevice();

    private void OnRemoveIphone(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not IphoneRow p) return;
        var r = MessageBox.Show(this,
            $"移除“{p.Name}”？\n\nESP32 会删除和这台 iPhone 的蓝牙配对。也请在 iPhone 的「设置 › 蓝牙」里点 NotiBridge 右边的 ⓘ，选“忽略此设备”。之后要再用需要重新配对。",
            "移除 iPhone", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (r == MessageBoxResult.OK) _model.Esp32.ForgetIphone(p.Id);
    }

    private void OnAddFromOverview(object sender, RoutedEventArgs e)
    {
        Go(NavDevices);
        ResetAddDevice();
    }

    private void OnShowEsp32(object sender, RoutedEventArgs e) => Go(NavEsp);
    private void OnEnableEsp32(object sender, RoutedEventArgs e) => _model.Esp32.UseEsp32 = true;
    private void OnDisableEsp32(object sender, RoutedEventArgs e) => _model.Esp32.UseEsp32 = false;

    // ---------------- 导航 ----------------

    private void OnNav(object sender, SelectionChangedEventArgs e)
    {
        for (var i = 0; i < _pages.Length; i++)
            _pages[i].Visibility = i == Nav.SelectedIndex ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Go(int page) => Nav.SelectedIndex = page;

    // ---------------- 引导 ----------------

    private void ShowOnboarding()
    {
        Main.Visibility = Visibility.Collapsed;
        Onboarding.Visibility = Visibility.Visible;
        _obIndex = 0;
        _phones = "";
        PhonesIphone.IsChecked = PhonesAndroid.IsChecked = PhonesBoth.IsChecked = false;
        // 引导页借用“设备与配对”里的添加设备面板
        AddDeviceHost.Content = null;
        ObPairingHost.Content = AddDevicePanel;
        UpdateOnboarding();
    }

    private void ShowMainUi()
    {
        Onboarding.Visibility = Visibility.Collapsed;
        Main.Visibility = Visibility.Visible;
        ObPairingHost.Content = null;
        AddDeviceHost.Content = AddDevicePanel;
        ResetAddDevice();
    }

    /// <summary>
    /// 当前要走的引导步骤：欢迎 → 你用什么手机 → [只有安卓 / 鸿蒙：要不要通话] → 通知 → 网络
    /// → [需要 ESP32：检测与刷写] → 添加第一台设备 → 完成。有 iPhone 或要通话 → ESP32 模式，否则纯软件。
    /// </summary>
    private List<FrameworkElement> ObFlow() =>
        _obPages.Where(p => (p != ObCalls || _phones == "android") && (p != ObEsp || _model.Esp32.UseEsp32)).ToList();

    private FrameworkElement ObCurrent => _obPages[_obIndex];

    private static string ObTitleFor(FrameworkElement p, MainWindow w) =>
        p == w.Ob0 ? "欢迎使用 NotiBridge" : p == w.ObPhones ? "你用什么手机？" : p == w.ObCalls ? "要在电脑上接打电话吗？"
        : p == w.Ob1 ? "允许显示通知" : p == w.Ob2 ? "允许局域网连接" : p == w.ObEsp ? "连接 ESP32 模块"
        : p == w.Ob4 ? "添加第一台设备" : "设置完成";

    private void UpdateOnboarding()
    {
        var flow = ObFlow();
        var page = ObCurrent;
        foreach (var p in _obPages) p.Visibility = p == page ? Visibility.Visible : Visibility.Collapsed;
        ObTitle.Text = ObTitleFor(page, this);
        ObStep.Text = $"第 {flow.IndexOf(page) + 1} 步，共 {flow.Count} 步";
        ObBack.Visibility = page == Ob0 ? Visibility.Hidden : Visibility.Visible;
        UpdateObNext();
        if (page == Ob1) _model.SendLocalTestNotification(); // 发一条通知，Windows 会登记本程序的通知权限
        if (page == Ob4)
        {
            if (_phones == "iphone") StartAddFlow(AddKind.Iphone);
            else if (_phones == "android") StartAddFlow(AddKind.Phone);
            else ResetAddDevice(); // iPhone + 安卓 / 鸿蒙：先选设备类型
        }
        else ResetAddDevice();
    }

    private void OnPhonesChanged(object sender, RoutedEventArgs e)
    {
        _phones = sender == PhonesIphone ? "iphone" : sender == PhonesAndroid ? "android" : "both";
        // 有 iPhone 就必须用 ESP32；只有安卓 / 鸿蒙时由下一步“要不要通话”决定（默认不需要）
        _model.Esp32.UseEsp32 = _phones != "android";
        UpdateOnboarding();
    }

    /// <summary>
    /// 底部主按钮。“添加设备”这一步还没有设备时显示“稍后添加”（普通样式，表示跳过）；
    /// 已有设备时显示“下一步”（主按钮样式），与 Mac 版引导一致。
    /// </summary>
    private void UpdateObNext()
    {
        var page = ObCurrent;
        var skip = (page == Ob4 && !_model.HasDevices) || (page == ObEsp && !_model.Esp32.FirmwareOk);
        ObNext.Content = page == Ob0 ? "开始设置" : page == Ob5 ? "完成" : page == Ob4 && skip ? "稍后添加" : skip ? "跳过" : "下一步";
        ObNext.IsEnabled = page != ObPhones || _phones.Length > 0;
        if (skip) ObNext.ClearValue(StyleProperty);
        else ObNext.SetResourceReference(StyleProperty, "AccentButtonStyle");
    }

    private void OnObNext(object sender, RoutedEventArgs e)
    {
        if (ObCurrent == Ob5)
        {
            _model.Onboarded = true;
            _model.Log("首次启动引导已完成");
            ShowMainUi();
            Go(NavOverview);
            return;
        }
        var flow = ObFlow();
        _obIndex = Array.IndexOf(_obPages, flow[flow.IndexOf(ObCurrent) + 1]);
        UpdateOnboarding();
    }

    private void OnObBack(object sender, RoutedEventArgs e)
    {
        var flow = ObFlow();
        var i = flow.IndexOf(ObCurrent);
        if (i <= 0) return;
        _obIndex = Array.IndexOf(_obPages, flow[i - 1]);
        UpdateOnboarding();
    }

    private void OnRestartOnboarding(object sender, RoutedEventArgs e)
    {
        _model.Onboarded = false;
        ShowOnboarding();
    }

    // ---------------- 操作 ----------------

    private void OnTestNotification(object sender, RoutedEventArgs e) => _model.SendLocalTestNotification();
    private void OnOpenNotificationSettings(object sender, RoutedEventArgs e) => AppModel.OpenNotificationSettings();
    private void OnOpenBluetooth(object sender, RoutedEventArgs e) => AppModel.OpenBluetoothSettings();
    private void OnOpenNetwork(object sender, RoutedEventArgs e) => AppModel.OpenNetworkSettings();
    private void OnHomepage(object sender, RoutedEventArgs e) => AppModel.OpenUri("https://github.com/Allen-1002/NotiBridge");
    private async void OnCheckUpdate(object sender, RoutedEventArgs e) => await _model.Updater.CheckAsync(manual: true);
    private async void OnInstallUpdate(object sender, RoutedEventArgs e) => await _model.Updater.PrimaryActionAsync();

    private void OnOpenReleasePage(object sender, RoutedEventArgs e)
    {
        if (_model.Updater.ReleasePage is { } url) AppModel.OpenUri(url);
    }
    private void OnCopyOtp(object sender, RoutedEventArgs e) => _model.CopyLastOtp();
    private void OnShowRecords(object sender, RoutedEventArgs e) => Go(NavRecords);
    private void OnClearRecords(object sender, RoutedEventArgs e) => _model.ClearRecords();
    private void OnOpenPairing(object sender, RoutedEventArgs e) => _model.OpenPairing();
    private void OnCancelPairing(object sender, RoutedEventArgs e) => _model.CancelPairing();

    private void OnRename(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not DeviceItem d) return;
        if (RenameDialog.Ask(this, d) is { } name) _model.Rename(d, name);
    }

    private void OnUnpair(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not DeviceItem d) return;
        var r = MessageBox.Show(this,
            $"移除“{d.Name}”？\n\n手机在线时会同步从手机上删除这台电脑；不在线时，手机下次连接会提示“这台电脑可能已取消配对”，需要在手机上手动删除。之后需要重新配对才能连接。",
            "移除手机",
            MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (r == MessageBoxResult.OK) _model.Unpair(d);
    }

    private void OnBlockApp(object sender, RoutedEventArgs e)
    {
        if (RecordList.SelectedItem is RecordItem r) _model.BlockApp(r);
    }

    // ---------------- 过滤 ----------------

    private void LoadFilterText()
    {
        var f = _model.FilterEdit;
        BlacklistBox.Text = f.Blacklist;
        WhitelistBox.Text = f.Whitelist;
        KeywordsBox.Text = f.Keywords;
        if (_model.WhitelistOnly) ModeWhite.IsChecked = true;
        else ModeAll.IsChecked = true;
    }

    private void OnModeChanged(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        _model.WhitelistOnly = ModeWhite.IsChecked == true;
    }

    private void OnSaveFilter(object sender, RoutedEventArgs e)
    {
        var f = _model.FilterEdit;
        f.Blacklist = BlacklistBox.Text;
        f.Whitelist = WhitelistBox.Text;
        f.Keywords = KeywordsBox.Text;
        _model.ApplyFilterText();
        LoadFilterText();
    }

    private void OnResetKeywords(object sender, RoutedEventArgs e) => _model.ResetKeywords();

    // ---------------- 安装 / 卸载 ----------------

    private void OnInstall(object sender, RoutedEventArgs e)
    {
        // 先退出自己（释放单实例锁），再启动安装好的那份
        try
        {
            Installer.Install();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"安装失败：{ex.Message}", "安装 NotiBridge", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        MessageBox.Show(this, "已安装，并创建了开始菜单和桌面快捷方式。接下来会从安装位置重新打开 NotiBridge。", "安装 NotiBridge",
            MessageBoxButton.OK, MessageBoxImage.Information);
        ((App)Application.Current).RestartFrom(Installer.InstalledExe);
    }

    private void OnUninstall(object sender, RoutedEventArgs e)
    {
        if (!Installer.ConfirmUninstall(this)) return;
        ((App)Application.Current).Uninstall();
    }

    private void OnResetAllData(object sender, RoutedEventArgs e)
    {
        var r = MessageBox.Show(this,
            "清除所有数据并重新开始？\n\n将删除：设置（过滤规则、同步开关、使用方式等）、这台电脑的设备标识、所有已配对手机的密钥，" +
            "并关闭开机启动、清空通知中心里的 NotiBridge 通知。所有手机都需要重新配对。\n\n" +
            "程序会自动重新打开并进入首次引导。",
            "清除所有数据", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (r != MessageBoxResult.Yes) return;
        ((App)Application.Current).ResetAllDataAndRestart();
    }
}
