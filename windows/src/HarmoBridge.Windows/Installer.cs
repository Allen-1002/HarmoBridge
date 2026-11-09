using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using Microsoft.Win32;

namespace HarmoBridge.Windows;

/// <summary>
/// 按当前用户安装（不需要管理员权限）：
/// 程序复制到 %LOCALAPPDATA%\Programs\HarmoBridge，创建开始菜单和桌面快捷方式，
/// 注册到“设置 &gt; 应用 &gt; 已安装的应用”（HKCU 卸载项），在那里可以直接卸载。
/// </summary>
internal static class Installer
{
    private const string AppName = "HarmoBridge";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\HarmoBridge";

    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", AppName);

    public static string InstalledExe => Path.Combine(InstallDir, "HarmoBridge.exe");

    private static string StartMenuLink =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "HarmoBridge.lnk");

    private static string DesktopLink =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "HarmoBridge.lnk");

    public static Version CurrentVersion => Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0);

    /// <summary>当前运行的就是已安装的那份</summary>
    public static bool IsRunningInstalled =>
        string.Equals(Path.GetFullPath(Environment.ProcessPath ?? ""), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

    public static bool IsInstalled => File.Exists(InstalledExe);

    public static Version? InstalledVersion
    {
        get
        {
            try
            {
                var v = FileVersionInfo.GetVersionInfo(InstalledExe);
                return new Version(v.FileMajorPart, v.FileMinorPart, v.FileBuildPart);
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    /// <summary>
    /// 启动时调用。返回 true 表示已经转交给安装好的程序，当前进程应退出。
    /// </summary>
    public static bool HandleStartup(AppSettings settings, string[] args)
    {
        if (IsRunningInstalled || args.Contains("--portable") || Environment.ProcessPath is null) return false;

        if (IsInstalled)
        {
            var installed = InstalledVersion;
            var current = new Version(CurrentVersion.Major, CurrentVersion.Minor, Math.Max(0, CurrentVersion.Build));
            if (installed is not null && installed >= current)
            {
                // 已安装同版本或更新版本：直接打开已安装的那份
                Launch(InstalledExe, args);
                return true;
            }
            var r = MessageBox.Show($"这台电脑上已经安装了 HarmoBridge {installed}。要更新到 {current.ToString(3)} 吗？\n\n" +
                                    "选“否”则以免安装方式运行这一份。", "更新 HarmoBridge",
                MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (r != MessageBoxResult.Yes) return false;
            return InstallAndLaunch(args);
        }

        if (settings.InstallDeclined) return false;
        var answer = MessageBox.Show(
            "要把 HarmoBridge 安装到这台电脑吗？\n\n" +
            "• 创建开始菜单和桌面快捷方式\n" +
            "• 出现在“设置 > 应用 > 已安装的应用”中，可以在那里卸载\n" +
            "• 只为当前用户安装，不需要管理员权限\n\n" +
            "选“否”则以免安装（绿色版）方式运行，之后可以在 设置 里再安装。",
            "安装 HarmoBridge", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (answer != MessageBoxResult.Yes)
        {
            settings.InstallDeclined = true;
            settings.Save();
            return false;
        }
        return InstallAndLaunch(args);
    }

    /// <summary>安装后启动已安装的程序。返回 true 表示当前进程应退出。</summary>
    public static bool InstallAndLaunch(string[] args)
    {
        try
        {
            Install();
        }
        catch (Exception e)
        {
            MessageBox.Show($"安装失败：{e.Message}\n\n将以免安装方式继续运行。", "安装 HarmoBridge",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        Launch(InstalledExe, args.Where(a => a != "--background").ToArray());
        return true;
    }

    public static void Install()
    {
        var src = Environment.ProcessPath ?? throw new InvalidOperationException("找不到程序路径");
        Directory.CreateDirectory(InstallDir);
        StopOtherInstances(InstalledExe);
        // 正在被替换的文件可能还没完全释放，重试几次
        for (var i = 0; ; i++)
        {
            try
            {
                File.Copy(src, InstalledExe, true);
                break;
            }
            catch (IOException) when (i < 10)
            {
                Thread.Sleep(300);
            }
        }
        CreateShortcut(StartMenuLink, InstalledExe);
        CreateShortcut(DesktopLink, InstalledExe);
        RegisterUninstall();
        // 开机启动项指向新位置
        if (AutoStartPointsTo(src)) AutoStart.SetPath(InstalledExe);
    }

    private static bool AutoStartPointsTo(string exe)
    {
        using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return k?.GetValue("HarmoBridge") is string s && s.Contains(exe, StringComparison.OrdinalIgnoreCase);
    }

    private static void RegisterUninstall()
    {
        using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
        var v = CurrentVersion;
        k.SetValue("DisplayName", "HarmoBridge");
        k.SetValue("DisplayVersion", $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}");
        k.SetValue("Publisher", "HarmoBridge");
        k.SetValue("DisplayIcon", $"\"{InstalledExe}\",0");
        k.SetValue("InstallLocation", InstallDir);
        k.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
        k.SetValue("QuietUninstallString", $"\"{InstalledExe}\" --uninstall --quiet");
        k.SetValue("URLInfoAbout", "https://github.com/Allen-1002/HarmoBridge");
        k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        k.SetValue("NoModify", 1, RegistryValueKind.DWord);
        k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        try
        {
            k.SetValue("EstimatedSize", (int)(new FileInfo(InstalledExe).Length / 1024), RegistryValueKind.DWord);
        }
        catch (Exception)
        {
        }
    }

    /// <summary>用 Windows 自带的 WScript.Shell 创建快捷方式。</summary>
    private static void CreateShortcut(string lnk, string target)
    {
        try
        {
            var type = Type.GetTypeFromProgID("WScript.Shell");
            if (type is null) return;
            dynamic shell = Activator.CreateInstance(type)!;
            dynamic sc = shell.CreateShortcut(lnk);
            sc.TargetPath = target;
            sc.WorkingDirectory = Path.GetDirectoryName(target);
            sc.IconLocation = target + ",0";
            sc.Description = "把鸿蒙手机通知同步到 Windows";
            sc.Save();
        }
        catch (Exception)
        {
            // 快捷方式失败不影响使用
        }
    }

    /// <summary>
    /// 卸载（从“已安装的应用”或 HarmoBridge.exe --uninstall 调用）：
    /// 退出正在运行的 HarmoBridge，删除快捷方式、开机启动项、通知注册、卸载项和程序文件；可选删除配对数据。
    /// </summary>
    public static void RunUninstall(bool quiet)
    {
        if (!quiet)
        {
            var r = MessageBox.Show("确定要卸载 HarmoBridge 吗？", "卸载 HarmoBridge", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (r != MessageBoxResult.Yes) return;
        }
        StopOtherInstances(null);
        AutoStart.Set(false);
        Notifier.Uninstall();
        TryDelete(StartMenuLink);
        TryDelete(DesktopLink);
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); }
        catch (Exception) { }

        if (!quiet)
        {
            var data = MessageBox.Show("同时删除设置和已配对手机的信息吗？\n\n选“否”则保留，重新安装后不用重新配对。", "卸载 HarmoBridge",
                MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (data == MessageBoxResult.Yes)
            {
                TryDeleteDir(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppName));
                TryDeleteDir(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName));
            }
        }

        // 程序不能删除正在运行的自己：交给一个延时执行的 cmd 删除安装目录
        if (Directory.Exists(InstallDir))
        {
            try
            {
                Process.Start(new ProcessStartInfo("cmd.exe",
                    $"/c timeout /t 2 /nobreak >nul & rmdir /s /q \"{InstallDir}\"")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden,
                });
            }
            catch (Exception)
            {
            }
        }
        if (!quiet) MessageBox.Show("HarmoBridge 已卸载。", "卸载 HarmoBridge", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private static void StopOtherInstances(string? onlyPath)
    {
        var me = Environment.ProcessId;
        foreach (var p in Process.GetProcessesByName("HarmoBridge"))
        {
            try
            {
                if (p.Id == me) continue;
                if (onlyPath is not null &&
                    !string.Equals(p.MainModule?.FileName, onlyPath, StringComparison.OrdinalIgnoreCase)) continue;
                p.Kill();
                p.WaitForExit(3000);
            }
            catch (Exception)
            {
            }
            finally
            {
                p.Dispose();
            }
        }
    }

    private static void Launch(string exe, string[] args)
    {
        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, Arguments = string.Join(' ', args) });
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception) { }
    }

    private static void TryDeleteDir(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, true); }
        catch (Exception) { }
    }
}
