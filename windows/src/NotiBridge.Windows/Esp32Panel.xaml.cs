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
        // 插上板子后自动检测：还没找到串口时每 2 秒找一次
        _detect.Tick += (_, _) =>
        {
            if (Esp is { HasPorts: false, NotBusy: true }) Detect();
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

    private void Refresh()
    {
        if (Esp is not { } esp) return;
        static void Mark(TextBlock t, bool ok)
        {
            t.Text = ok ? "✓" : "○";
            if (ok) t.Foreground = Ok;
            else t.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        }

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
