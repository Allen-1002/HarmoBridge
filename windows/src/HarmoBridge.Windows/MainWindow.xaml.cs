using System.Collections.Specialized;
using System.ComponentModel;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;

namespace HarmoBridge.Windows;

public partial class MainWindow : Window
{
    private static readonly string[] ObTitles = ["欢迎使用 HarmoBridge", "允许显示通知", "允许局域网连接", "蓝牙绑定（按需）", "配对手机", "设置完成"];
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
        _obPages = [Ob0, Ob1, Ob2, Ob3, Ob4, Ob5];
        VersionText.Text = $"HarmoBridge for Windows {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3)} · 与 Mac 版、鸿蒙手机端使用同一套加密协议";

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

    private void UpdatePairIdle() => PairIdle.Visibility = _model.IsPairing ? Visibility.Collapsed : Visibility.Visible;

    private void OnRecordsChanged(object? sender, NotifyCollectionChangedEventArgs? e)
    {
        RecentList.ItemsSource = _model.Records.Take(6).ToList();
        NoRecordsHint.Visibility = _model.Records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnDevicesChanged(object? sender, NotifyCollectionChangedEventArgs? e)
    {
        NoDevicesHint.Visibility = _model.Devices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
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
        ObNext.Content = _obIndex == 0 ? "开始设置" : _obIndex == _obPages.Length - 1 ? "完成" :
            _obIndex == 4 && _model.Devices.Count == 0 ? "稍后配对" : "下一步";
        if (_obIndex == 1) _model.SendLocalTestNotification(); // 发一条通知，Windows 会登记本程序的通知权限
        if (_obIndex == 4 && !_model.IsPairing && _model.Devices.Count == 0) _model.OpenPairing();
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
        UpdateOnboarding();
    }

    private void OnObBack(object sender, RoutedEventArgs e)
    {
        if (_obIndex == 0) return;
        _obIndex--;
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
    private void OnHomepage(object sender, RoutedEventArgs e) => AppModel.OpenUri("https://github.com/Allen-1002/HarmoBridge");
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

    private void OnUnpair(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not DeviceItem d) return;
        var r = MessageBox.Show(this, $"取消与“{d.Name}”的配对？之后这台手机需要重新配对才能连接。", "取消配对",
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
}
