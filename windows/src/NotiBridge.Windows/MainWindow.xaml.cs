using System.Collections.Specialized;
using System.ComponentModel;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;

namespace NotiBridge.Windows;

public partial class MainWindow : Window
{
    private static readonly string[] ObTitles =
        ["欢迎使用 NotiBridge", "选择使用方式", "连接 ESP32 模块", "允许显示通知", "允许局域网连接", "蓝牙绑定（按需）", "配对手机", "设置完成"];
    private readonly AppModel _model;
    private FrameworkElement[] _pages = [];
    private FrameworkElement[] _obPages = [];
    private int _obIndex;

    public MainWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        DataContext = model;
        _pages = [Page0, Page1, Page2, Page3, Page4, Page5];
        _obPages = [Ob0, ObMode, ObEsp, Ob1, Ob2, Ob3, Ob4, Ob5];
        VersionText.Text = $"NotiBridge for Windows {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3)} · 与 Mac 版、手机端使用同一套加密协议";

        model.Records.CollectionChanged += OnRecordsChanged;
        model.Devices.CollectionChanged += OnDevicesChanged;
        model.PropertyChanged += OnModelChanged;
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

    private void OnDismissRepairNotice(object sender, RoutedEventArgs e) => _model.DismissRepairNotice();

    private void UpdatePairIdle() => PairIdle.Visibility = _model.IsPairing ? Visibility.Collapsed : Visibility.Visible;

    private void OnRecordsChanged(object? sender, NotifyCollectionChangedEventArgs? e)
    {
        RecentList.ItemsSource = _model.Records.Take(6).ToList();
        NoRecordsHint.Visibility = _model.Records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnDevicesChanged(object? sender, NotifyCollectionChangedEventArgs? e)
    {
        NoDevicesHint.Visibility = _model.Devices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        // 引导“配对手机”这一步：配对完成后按钮立即从“稍后配对”变成“下一步”
        if (Onboarding.Visibility == Visibility.Visible && _obPages.Length > 0) UpdateObNext();
    }

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
        // 引导页借用“设备与配对”里的配对面板
        PairingHost.Content = null;
        ObPairingHost.Content = PairingPanel;
        UpdateOnboarding();
    }

    private void ShowMainUi()
    {
        Onboarding.Visibility = Visibility.Collapsed;
        Main.Visibility = Visibility.Visible;
        ObPairingHost.Content = null;
        PairingHost.Content = PairingPanel;
    }

    private void UpdateOnboarding()
    {
        for (var i = 0; i < _obPages.Length; i++)
            _obPages[i].Visibility = i == _obIndex ? Visibility.Visible : Visibility.Collapsed;
        ObTitle.Text = ObTitles[_obIndex];
        ObStep.Text = $"第 {_obIndex + 1} 步，共 {_obPages.Length} 步";
        ObBack.Visibility = _obIndex == 0 ? Visibility.Hidden : Visibility.Visible;
        var page = _obPages[_obIndex];
        UpdateObNext();
        if (page == Ob1) _model.SendLocalTestNotification(); // 发一条通知，Windows 会登记本程序的通知权限
        if (page == ObEsp && !_model.Esp32.Scanned) _model.Esp32.Scan();
        if (page == Ob4 && !_model.IsPairing && _model.Devices.Count == 0) _model.OpenPairing();
    }

    /// <summary>
    /// 底部主按钮。“配对手机”这一步还没有配对时显示“稍后配对”（普通样式，表示跳过）；
    /// 已有配对的手机时显示“下一步”（主按钮样式），与 Mac 版引导一致。
    /// </summary>
    private void UpdateObNext()
    {
        var page = _obPages[_obIndex];
        var skip = page == Ob4 && _model.Devices.Count == 0;
        ObNext.Content = _obIndex == 0 ? "开始设置" : _obIndex == _obPages.Length - 1 ? "完成" : skip ? "稍后配对" : "下一步";
        if (skip) ObNext.ClearValue(StyleProperty);
        else ObNext.SetResourceReference(StyleProperty, "AccentButtonStyle");
    }

    private void OnObNext(object sender, RoutedEventArgs e)
    {
        if (_obIndex == _obPages.Length - 1)
        {
            _model.Onboarded = true;
            _model.Log("首次启动引导已完成");
            ShowMainUi();
            Go(0);
            return;
        }
        _obIndex++;
        if (_obPages[_obIndex] == ObEsp && !_model.Esp32.UseEsp32) _obIndex++; // 纯软件跳过 ESP32 步骤
        UpdateOnboarding();
    }

    private void OnObBack(object sender, RoutedEventArgs e)
    {
        if (_obIndex == 0) return;
        _obIndex--;
        if (_obPages[_obIndex] == ObEsp && !_model.Esp32.UseEsp32) _obIndex--;
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
    private void OnShowRecords(object sender, RoutedEventArgs e) => Go(1);
    private void OnClearRecords(object sender, RoutedEventArgs e) => _model.ClearRecords();
    private void OnOpenPairing(object sender, RoutedEventArgs e) => _model.OpenPairing();
    private void OnCancelPairing(object sender, RoutedEventArgs e) => _model.CancelPairing();

    private void OnPairFromOverview(object sender, RoutedEventArgs e)
    {
        _model.OpenPairing();
        Go(2);
    }

    private void OnRename(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not DeviceItem d) return;
        if (RenameDialog.Ask(this, d) is { } name) _model.Rename(d, name);
    }

    private void OnUnpair(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not DeviceItem d) return;
        var r = MessageBox.Show(this,
            $"取消与“{d.Name}”的配对？\n\n手机在线时会同步从手机上删除这台电脑；不在线时，手机下次连接会提示“这台电脑可能已取消配对”，需要在手机上手动删除。之后需要重新配对才能连接。",
            "取消配对",
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
