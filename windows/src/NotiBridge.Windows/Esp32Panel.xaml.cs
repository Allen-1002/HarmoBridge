using System.Windows;
using System.Windows.Controls;

namespace NotiBridge.Windows;

public partial class Esp32Panel : UserControl
{
    public Esp32Panel()
    {
        InitializeComponent();
    }

    private Esp32Manager? Esp => DataContext as Esp32Manager;

    private void OnScan(object sender, RoutedEventArgs e)
    {
        Esp?.Scan();
        ScanButton.Content = "重新检测";
    }

    private async void OnCheck(object sender, RoutedEventArgs e)
    {
        if (Esp is { } esp) await esp.CheckFirmwareAsync();
    }

    private void OnFlash(object sender, RoutedEventArgs e) => Esp?.Flash();
    private void OnSkip(object sender, RoutedEventArgs e) => Esp?.SkipFlash();
    private void OnPair(object sender, RoutedEventArgs e) => Esp?.PairNewIphone();
    private void OnForget(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("删除后 iPhone 需要重新配对，并在 iPhone 的蓝牙设置里“忽略此设备”。继续吗？", "删除 iPhone 配对",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            Esp?.ForgetIphones();
    }
}
