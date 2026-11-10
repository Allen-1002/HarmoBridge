using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using NotiBridge.Core;

namespace NotiBridge.Windows;

public partial class Esp32Panel : UserControl
{
    private static readonly Brush Ok = new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A));
    private readonly DispatcherTimer _detect = new() { Interval = TimeSpan.FromSeconds(2) };
    private Esp32Manager? _bound;

    /// <summary>“添加 iPhone”按钮（首次引导里关掉：下一步就是添加设备）</summary>
    public bool ShowAddIphone { get; set; } = true;
    public event Action? AddIphoneRequested;

    public Esp32Panel()
    {
        InitializeComponent();
        DataContextChanged += (_, _) => Bind(DataContext as Esp32Manager);
        IsVisibleChanged += (_, _) => OnVisibleChanged();
        // 插上板子后自动检测：每 2 秒看一次串口列表（Esp32Manager 也会在后台检查），有变化就刷新界面
        _detect.Tick += (_, _) =>
        {
            if (Esp is { NotBusy: true } esp && esp.RefreshPortsIfChanged()) Refresh();
        };
    }

    private Esp32Manager? Esp => DataContext as Esp32Manager;

    private void Bind(Esp32Manager? esp)
    {
        if (_bound is not null) _bound.PropertyChanged -= OnEspChanged;
        _bound = esp;
        if (esp is not null) esp.PropertyChanged += OnEspChanged;
        Refresh();
    }

    private void OnEspChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Refresh);

    private void OnVisibleChanged()
    {
        if (IsVisible)
        {
            if (Esp is { Scanned: false }) Detect();
            _detect.Start();
        }
        else _detect.Stop();
    }

    /// <summary>找串口；找到了而且还没连上固件，就检测固件</summary>
    private async void Detect()
    {
        if (Esp is not { } esp) return;
        esp.Scan();
        if (esp.Selected is not null && esp.Link is null && esp.NotBusy) await esp.CheckFirmwareAsync();
    }

    private static void Mark(TextBlock t, bool ok)
    {
        t.Text = ok ? "✓" : "○";
        if (ok) t.Foreground = Ok;
        else t.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
    }

    private void Refresh()
    {
        if (Esp is not { } esp) return;

        // 板子
        Mark(BoardMark, esp.Selected is not null);
        BoardText.Text = esp.Selected is { } p
            ? $"已连接 · {p.Label}"
            : esp.Message.Length > 0 && esp.Scanned ? esp.Message : "未检测到。用支持数据传输的 USB 线连接 ESP32，插上后会自动检测。";
        PortBox.Visibility = esp.Ports.Count > 1 ? Visibility.Visible : Visibility.Collapsed;

        // 固件
        Mark(FirmwareMark, esp.FirmwareOk);
        FlashRow.Visibility = !esp.FirmwareOk && !esp.Flashing && esp.HasPorts ? Visibility.Visible : Visibility.Collapsed;

        // iPhone
        var iphones = esp.Iphones;
        Mark(IphoneMark, esp.Link is not null && iphones.Any(i => i.AncsReady));
        if (esp.Link is null)
        {
            IphoneText.Text = esp.FirmwareOk ? esp.LinkText : "固件就绪后可以添加 iPhone";
            IphoneText.Visibility = Visibility.Visible;
            IphoneList.ItemsSource = null;
            AddIphoneButton.Visibility = Visibility.Collapsed;
            ForgetAllButton.Visibility = Visibility.Collapsed;
        }
        else
        {
            var anyReady = iphones.Any(i => i.AncsReady);
            IphoneText.Text = iphones.Count == 0 ? "还没有配对 iPhone" : !anyReady ? esp.LinkText : "";
            IphoneText.Visibility = IphoneText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            IphoneList.ItemsSource = iphones.Select(i => new { Name = IphoneDisplay.Name(i), Status = IphoneDisplay.Status(i) }).ToList();
            AddIphoneButton.Visibility = ShowAddIphone ? Visibility.Visible : Visibility.Collapsed;
            ForgetAllButton.Visibility = iphones.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        BackupInfo.Text = esp.HasBackups ? esp.BackupText : "还没有备份（第一次刷写时自动备份）";
        RefreshCall(esp);
    }

    private void RefreshCall(Esp32Manager esp)
    {
        Mark(CallMark, esp.Hfp is { Connected: true });
        var supported = esp.FirmwareSupportsCalls;
        var h = esp.Hfp;
        CallText.Text = !supported ? "需要固件 1.3.0 或更新：在上面的“固件”一行更新后即可使用通话。"
            : h is null ? "等待 ESP32…"
            : h.Connected ? $"已连接 {(h.Name.Length == 0 ? "手机" : h.Name)}{(h.Operator.Length == 0 ? "" : " · " + h.Operator)}"
            : h.State == "connecting" ? "正在连接手机…"
            : esp.Phones.Count == 0 ? "还没有配对手机" : "手机未连接（ESP32 会自动重连）";
        PairCodeText.Text = esp.PairCode is { } code ? $"手机上显示的配对码应为 {code}，一致时在手机上点“配对”。" : "";
        PairCodeText.Visibility = esp.PairCode is null ? Visibility.Collapsed : Visibility.Visible;
        var connected = supported && h is { Connected: true };
        var c = esp.Call;
        CallActive.Visibility = connected && !c.IsIdle ? Visibility.Visible : Visibility.Collapsed;
        CallLabel.Text = $"{c.Label} {c.Number}";
        AnswerButton.Visibility = c.State == "incoming" ? Visibility.Visible : Visibility.Collapsed;
        HangUpButton.Content = c.State == "incoming" ? "拒接" : "挂断";
        DialRow.Visibility = connected && c.IsIdle ? Visibility.Visible : Visibility.Collapsed;
        PhoneList.ItemsSource = supported
            ? esp.Phones.Select(p => new
            {
                p.Id, Name = p.DisplayName, Status = (p.Connected ? " 已连接" : " 未连接") + (p.Preferred ? " · 优先" : ""),
                CanConnect = !p.Connected, ConnectText = esp.Hfp is { Connected: true } ? "切换到这台" : "连接",
                CanPrefer = esp.Phones.Count > 1, PreferText = p.Preferred ? "取消优先" : "设为优先", p.Preferred,
            }).ToList()
            : null;
        PairPhoneRow.Visibility = supported ? Visibility.Visible : Visibility.Collapsed;
        PairPhoneButton.Content = esp.Phones.Count == 0 ? "配对手机" : "配对新手机";
    }

    private void OnAnswer(object sender, RoutedEventArgs e) => Esp?.Answer();
    private void OnHangUp(object sender, RoutedEventArgs e) => Esp?.HangUp();
    private void OnDial(object sender, RoutedEventArgs e) => Esp?.Dial(DialBox.Text);
    private void OnRedial(object sender, RoutedEventArgs e) => Esp?.Redial();
    private void OnDialKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) Esp?.Dial(DialBox.Text);
    }
    private void OnPairPhone(object sender, RoutedEventArgs e) => Esp?.PairNewIphone();
    private void OnConnectPhone(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id }) Esp?.SwitchPhone(id);
    }
    private void OnPreferPhone(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id } && Esp is { } esp)
            esp.PreferPhone(esp.Phones.FirstOrDefault(p => p.Id == id) is { Preferred: true } ? null : id);
    }
    private void OnForgetPhone(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id } &&
            MessageBox.Show("删除这台手机的通话配对？也请在手机的蓝牙设置里忽略 NotiBridge。", "删除手机",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            Esp?.ForgetPhone(id);
    }

    private void OnScan(object sender, RoutedEventArgs e) => Detect();

    private async void OnCheck(object sender, RoutedEventArgs e)
    {
        if (Esp is { } esp) await esp.CheckFirmwareAsync();
    }

    private async void OnPortChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded || e.AddedItems.Count == 0 || Esp is not { NotBusy: true } esp) return;
        if (esp.Link is null) await esp.CheckFirmwareAsync();
    }

    private void OnFlash(object sender, RoutedEventArgs e) => Esp?.Flash();
    private void OnReveal(object sender, RoutedEventArgs e) => Esp?.RevealBackups();
    private void OnAddIphone(object sender, RoutedEventArgs e) => AddIphoneRequested?.Invoke();

    private void OnRestore(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("会把这块板子恢复成第一次刷写 NotiBridge 之前的样子，iPhone 配对也会一起清除。备份文件会保留，之后还可以再刷写 NotiBridge。", "还原原固件",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            Esp?.RestoreOriginal();
    }

    private void OnForget(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("所有 iPhone 都需要重新配对，也请在每台 iPhone 的「设置 › 蓝牙」里忽略 NotiBridge。继续吗？", "删除全部 iPhone 配对",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            Esp?.ForgetIphones();
    }
}

/// <summary>iPhone 的显示名和状态文字（设备列表、ESP32 面板、添加设备共用）</summary>
internal static class IphoneDisplay
{
    public static string Name(PairedIphone p) => string.IsNullOrEmpty(p.Name) ? "iPhone" : p.Name;

    public static string Status(PairedIphone p) =>
        p.AncsReady ? "通知已就绪" : p.Connected ? "已连接，等待 iPhone 允许共享通知" : "未连接（iPhone 在附近时会自动连接）";
}
