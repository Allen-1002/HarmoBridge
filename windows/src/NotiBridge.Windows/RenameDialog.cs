using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace NotiBridge.Windows;

/// <summary>给已配对手机改名的小对话框。返回新名字；空字符串表示恢复原名；null 表示取消。</summary>
internal static class RenameDialog
{
    public static string? Ask(Window owner, DeviceItem d)
    {
        string? result = null;
        var box = new TextBox { Text = d.Name, Margin = new Thickness(0, 8, 0, 4), Padding = new Thickness(6, 4, 6, 4) };
        var hint = new TextBlock
        {
            Text = $"手机原名：{d.OriginalName}\n名字只保存在这台电脑上。配对了多台手机时，通知会用这个名字标出来源。",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.7, FontSize = 12,
        };
        var win = new Window
        {
            Title = "给手机改名", Owner = owner, Width = 380, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
        };
        var save = new Button { Content = "保存", IsDefault = true, MinWidth = 72, Margin = new Thickness(8, 0, 0, 0) };
        var cancel = new Button { Content = "取消", IsCancel = true, MinWidth = 72, Margin = new Thickness(8, 0, 0, 0) };
        var restore = new Button { Content = "恢复原名", MinWidth = 72, IsEnabled = d.IsRenamed };
        save.Click += (_, _) => { result = box.Text; win.DialogResult = true; };
        restore.Click += (_, _) => { result = ""; win.DialogResult = true; };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        buttons.Children.Add(restore);
        buttons.Children.Add(save);
        buttons.Children.Add(cancel);
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = "名字", FontWeight = FontWeights.SemiBold });
        panel.Children.Add(box);
        panel.Children.Add(hint);
        panel.Children.Add(buttons);
        win.Content = panel;
        win.Loaded += (_, _) => { box.Focus(); box.SelectAll(); Keyboard.Focus(box); };
        return win.ShowDialog() == true ? result : null;
    }
}
