using System.Windows;
using System.Windows.Controls;

namespace HarmoBridge.Windows;

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
}
