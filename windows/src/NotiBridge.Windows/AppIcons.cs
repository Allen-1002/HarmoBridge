using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace NotiBridge.Windows;

/// <summary>
/// 为手机通知找一个“原应用图标”，显示在 Windows 通知左侧。
/// 优先使用电脑上已安装的对应应用（开始菜单快捷方式）的图标，找不到则生成彩色首字母图标。与 Mac 端 AppIconProvider 一致。
/// </summary>
internal sealed class AppIcons
{
    /// <summary>鸿蒙 / 安卓包名 → Windows 开始菜单里可能的名称（常见应用）</summary>
    private static readonly Dictionary<string, string[]> KnownMap = new()
    {
        ["com.tencent.wechat"] = ["微信", "WeChat", "Weixin"],
        ["com.tencent.mm"] = ["微信", "WeChat", "Weixin"],
        ["com.tencent.mqq"] = ["QQ"],
        ["com.tencent.hm.qq"] = ["QQ"],
        ["com.ss.hm.ugc.aweme"] = ["抖音"],
        ["com.alibaba.android.rimet"] = ["钉钉", "DingTalk"],
        ["com.huawei.hmos.email"] = ["Outlook", "Mail", "邮件"],
        ["com.huawei.hmos.calendar"] = ["日历", "Calendar"],
        ["com.bilibili.app.hm"] = ["哔哩哔哩", "bilibili"],
        ["com.tencent.wework"] = ["企业微信", "WXWork"],
        ["com.ss.android.lark"] = ["飞书", "Lark", "Feishu"],
        // 安卓
        ["tv.danmaku.bili"] = ["哔哩哔哩", "bilibili"],
        ["com.ss.android.ugc.aweme"] = ["抖音"],
        ["com.google.android.gm"] = ["Gmail", "Outlook", "Mail", "邮件"],
        ["com.android.email"] = ["Outlook", "Mail", "邮件"],
        ["com.google.android.calendar"] = ["日历", "Calendar"],
        ["com.whatsapp"] = ["WhatsApp"],
        ["org.telegram.messenger"] = ["Telegram"],
    };

    private static readonly Color[] Palette =
    [
        Color.FromRgb(0x3B, 0x82, 0xF6), Color.FromRgb(0x10, 0xB9, 0x81), Color.FromRgb(0xF5, 0x9E, 0x0B),
        Color.FromRgb(0xEF, 0x44, 0x44), Color.FromRgb(0x8B, 0x5C, 0xF6), Color.FromRgb(0x06, 0xB6, 0xD4),
        Color.FromRgb(0xEC, 0x48, 0x99), Color.FromRgb(0x63, 0x66, 0xF1),
    ];

    private readonly string _dir = Directory.CreateDirectory(Path.Combine(Paths.CacheDir, "icons")).FullName;
    private readonly Dictionary<string, string> _cache = [];
    private Dictionary<string, string>? _shortcuts;
    private readonly object _gate = new();

    public static Color AvatarColor(string key)
    {
        var h = 0;
        foreach (var r in key.EnumerateRunes()) h = (h * 31 + r.Value) % 997;
        return Palette[Math.Abs(h) % Palette.Length];
    }

    /// <summary>返回图标 PNG 文件路径（必须在 UI 线程调用，因为用到 WPF 绘图）。</summary>
    public string? IconFile(string bundleName, string appName)
    {
        var key = string.IsNullOrEmpty(bundleName) ? appName : bundleName;
        lock (_gate)
        {
            if (_cache.TryGetValue(key, out var cached) && File.Exists(cached)) return cached;
        }
        var path = Path.Combine(_dir, Safe(key) + ".png");
        try
        {
            var image = InstalledAppIcon(bundleName, appName) ?? LetterIcon(string.IsNullOrEmpty(appName) ? key : appName, key);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(image));
            using (var fs = File.Create(path)) enc.Save(fs);
            lock (_gate) _cache[key] = path;
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private BitmapSource? InstalledAppIcon(string bundleName, string appName)
    {
        var map = Shortcuts();
        var names = new List<string>();
        if (KnownMap.TryGetValue(bundleName, out var known)) names.AddRange(known);
        if (!string.IsNullOrEmpty(appName)) names.Add(appName);
        foreach (var n in names)
        {
            if (map.TryGetValue(n.ToLowerInvariant(), out var lnk) && ShellIcon(lnk) is { } img) return img;
        }
        return null;
    }

    /// <summary>扫描开始菜单，建立“快捷方式名 → 路径”索引。</summary>
    private Dictionary<string, string> Shortcuts()
    {
        if (_shortcuts is not null) return _shortcuts;
        var map = new Dictionary<string, string>();
        string[] roots =
        [
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
        ];
        foreach (var root in roots.Where(Directory.Exists))
        {
            try
            {
                foreach (var f in Directory.EnumerateFiles(root, "*.lnk", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }))
                    map.TryAdd(Path.GetFileNameWithoutExtension(f).ToLowerInvariant(), f);
            }
            catch (Exception)
            {
                // 忽略无权限目录
            }
        }
        _shortcuts = map;
        return map;
    }

    private static BitmapSource LetterIcon(string name, string key)
    {
        const int size = 256;
        var color = AvatarColor(key);
        var light = Color.FromRgb((byte)(color.R + (255 - color.R) / 4), (byte)(color.G + (255 - color.G) / 4), (byte)(color.B + (255 - color.B) / 4));
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            var brush = new LinearGradientBrush(light, color, 90);
            dc.DrawRoundedRectangle(brush, null, new Rect(8, 8, size - 16, size - 16), 56, 56);
            var letter = new StringInfo(name).LengthInTextElements > 0 ? StringInfo.GetNextTextElement(name) : "?";
            var ft = new FormattedText(letter, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Microsoft YaHei UI, Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                120, Brushes.White, 1.0);
            dc.DrawText(ft, new Point((size - ft.Width) / 2, (size - ft.Height) / 2));
        }
        var bmp = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(dv);
        bmp.Freeze();
        return bmp;
    }

    // ---- Shell 图标（IShellItemImageFactory，可取到 256px 图标） ----

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [PreserveSig]
        int GetImage(NativeSize size, int flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSize(int cx, int cy)
    {
        public int Cx = cx;
        public int Cy = cy;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    private static BitmapSource? ShellIcon(string path)
    {
        const int SiigbfIconOnly = 0x4;
        try
        {
            SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out var factory);
            if (factory.GetImage(new NativeSize(256, 256), SiigbfIconOnly, out var hbmp) != 0 || hbmp == IntPtr.Zero) return null;
            try
            {
                var src = Imaging.CreateBitmapSourceFromHBitmap(hbmp, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                src.Freeze();
                return src;
            }
            finally
            {
                DeleteObject(hbmp);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string Safe(string s) => new(s.Select(c => char.IsLetterOrDigit(c) || c == '.' ? c : '_').ToArray());
}
