using System.Security.Cryptography;
using System.Text;
using HarmoBridge.Core;
using Microsoft.Toolkit.Uwp.Notifications;

namespace HarmoBridge.Windows;

/// <summary>
/// Windows 通知中心（Toast）。通知 Tag = hash(手机 deviceId + 通知 id)，同 Tag 再次投递即替换，手机撤销即移除。
/// 未打包的桌面程序由 ToastNotificationManagerCompat 自动注册 AUMID，不需要安装包。
/// </summary>
internal sealed class Notifier
{
    private const string Group = "hb";
    private readonly AppIcons _icons = new();
    private readonly Action<string> _log;

    public event Action<string>? Activated; // 参数：action（open / copy:<code>）

    public Notifier(Action<string> log)
    {
        _log = log;
        try
        {
            ToastNotificationManagerCompat.OnActivated += e =>
            {
                var args = ToastArguments.Parse(e.Argument);
                var action = args.TryGetValue("action", out var a) ? a : "open";
                if (action == "copy" && args.TryGetValue("code", out var code)) action = "copy:" + code;
                Activated?.Invoke(action);
            };
        }
        catch (Exception ex)
        {
            _log($"通知中心初始化失败：{ex.Message}");
        }
    }

    public static string Tag(string deviceId, string id)
    {
        // Tag 最长 64 字符：用哈希
        var h = SHA256.HashData(Encoding.UTF8.GetBytes(deviceId + "|" + id));
        return Convert.ToHexString(h, 0, 16);
    }

    public void Show(MirroredNotification n, string deviceId, string phoneName, bool showPhone)
    {
        var app = string.IsNullOrEmpty(n.AppName) ? n.BundleName : n.AppName;
        try
        {
            var b = new ToastContentBuilder()
                .AddArgument("action", "open")
                .AddText(n.IsTest ? $"[测试] {app}" : app, hintMaxLines: 1);
            if (!string.IsNullOrEmpty(n.Title)) b.AddText(n.Title);
            if (!string.IsNullOrEmpty(n.Text)) b.AddText(n.Text);
            if (showPhone) b.AddAttributionText($"来自 {phoneName}");
            b.AddCustomTimeStamp(n.Time.LocalDateTime);
            if (_icons.IconFile(n.BundleName, app) is { } icon)
                b.AddAppLogoOverride(new Uri(icon), ToastGenericAppLogoCrop.Default);
            b.Show(t =>
            {
                t.Tag = Tag(deviceId, n.Id);
                t.Group = Group;
            });
        }
        catch (Exception ex)
        {
            _log($"显示通知失败：{ex.Message}");
        }
    }

    public void Remove(string deviceId, IEnumerable<string> ids)
    {
        foreach (var id in ids)
        {
            try { ToastNotificationManagerCompat.History.Remove(Tag(deviceId, id), Group); }
            catch (Exception) { }
        }
    }

    public void ShowOtp(string code, string app)
    {
        try
        {
            new ToastContentBuilder()
                .AddArgument("action", "open")
                .AddText($"验证码 {code} 已复制")
                .AddText($"来自 {app} · 2 分钟后自动从剪贴板清除")
                .AddButton(new ToastButton().SetContent("再次复制").AddArgument("action", "copy").AddArgument("code", code)
                    .SetBackgroundActivation())
                .Show(t =>
                {
                    t.Tag = "otp";
                    t.Group = Group;
                    t.ExpirationTime = DateTimeOffset.Now.AddMinutes(2);
                });
        }
        catch (Exception ex)
        {
            _log($"显示验证码通知失败：{ex.Message}");
        }
    }

    public void ShowLocal(string title, string text)
    {
        try
        {
            new ToastContentBuilder().AddArgument("action", "open").AddText(title).AddText(text).Show();
        }
        catch (Exception ex)
        {
            _log($"显示通知失败：{ex.Message}");
        }
    }

    /// <summary>卸载前清理通知注册（开始菜单/注册表中的 AUMID）。</summary>
    public static void Uninstall()
    {
        try { ToastNotificationManagerCompat.Uninstall(); }
        catch (Exception) { }
    }
}
