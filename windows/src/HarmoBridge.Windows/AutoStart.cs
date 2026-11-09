using Microsoft.Win32;

namespace HarmoBridge.Windows;

/// <summary>开机启动：写当前用户的 Run 注册表项，不需要管理员权限。</summary>
internal static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "HarmoBridge";

    public static bool IsEnabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(Name) is string s && s.Contains(Environment.ProcessPath ?? "\u0000", StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>安装后把开机启动项改指向安装位置。</summary>
    public static void SetPath(string exe)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        k.SetValue(Name, $"\"{exe}\" --background");
    }

    public static void Set(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on && Environment.ProcessPath is { } exe)
            k.SetValue(Name, $"\"{exe}\" --background");
        else
            k.DeleteValue(Name, false);
    }
}
