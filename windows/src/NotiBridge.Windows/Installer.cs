using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using Microsoft.Win32;

namespace NotiBridge.Windows;

/// <summary>
/// 按当前用户安装（不需要管理员权限）：
/// 程序复制到 %LOCALAPPDATA%\Programs\NotiBridge，创建开始菜单和桌面快捷方式，
/// 注册到“设置 &gt; 应用 &gt; 已安装的应用”（HKCU 卸载项），在那里可以直接卸载。
/// </summary>
internal static class Installer
{
    private const string AppName = "NotiBridge";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\NotiBridge";

    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", AppName);

    public static string InstalledExe => Path.Combine(InstallDir, "NotiBridge.exe");

    private static string StartMenuLink =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "NotiBridge.lnk");

    private static string DesktopLink =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "NotiBridge.lnk");

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
        // --updated：自动更新刚替换完自己，不再提示安装
        if (IsRunningInstalled || args.Contains("--portable") || args.Contains("--updated") ||
            Environment.ProcessPath is null) return false;

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
            var r = MessageBox.Show($"这台电脑上已经安装了 NotiBridge {installed}。要更新到 {current.ToString(3)} 吗？\n\n" +
                                    "选“否”则以免安装方式运行这一份。", "更新 NotiBridge",
                MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (r != MessageBoxResult.Yes) return false;
            return InstallAndLaunch(args);
        }

        if (settings.InstallDeclined) return false;
        var answer = MessageBox.Show(
            "要把 NotiBridge 安装到这台电脑吗？\n\n" +
            "• 创建开始菜单和桌面快捷方式\n" +
            "• 出现在“设置 > 应用 > 已安装的应用”中，可以在那里卸载\n" +
            "• 只为当前用户安装，不需要管理员权限\n\n" +
            "选“否”则以免安装（绿色版）方式运行，之后可以在 设置 里再安装。",
            "安装 NotiBridge", MessageBoxButton.YesNo, MessageBoxImage.Question);
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
            MessageBox.Show($"安装失败：{e.Message}\n\n将以免安装方式继续运行。", "安装 NotiBridge",
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
        ReplaceFile(src, InstalledExe);
        CreateShortcut(StartMenuLink, InstalledExe);
        CreateShortcut(DesktopLink, InstalledExe);
        RegisterUninstall();
        // 开机启动项指向新位置
        if (AutoStartPointsTo(src)) AutoStart.SetPath(InstalledExe);
    }

    /// <summary>
    /// 用 src 覆盖 dest。旧进程刚退出时 exe 可能还被系统（杀毒扫描等）占用，先重试约 10 秒；
    /// 仍然失败就把旧文件改名（正在运行的 exe 也允许改名），再把新文件复制过去。旧文件下次启动时清理。
    /// </summary>
    public static void ReplaceFile(string src, string dest)
    {
        Exception? last = null;
        for (var i = 0; i < 20; i++)
        {
            try
            {
                File.Copy(src, dest, true);
                return;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                last = e;
                Thread.Sleep(500);
            }
        }
        if (!File.Exists(dest)) throw last ?? new IOException($"无法写入 {dest}");
        var moved = $"{dest}.old-{DateTime.Now:yyyyMMddHHmmss}";
        File.Move(dest, moved);
        try
        {
            File.Copy(src, dest, true);
        }
        catch (Exception)
        {
            // 复制失败：把旧文件放回去，保证还能打开原来的版本
            try { File.Move(moved, dest, true); } catch (Exception) { }
            throw;
        }
    }

    /// <summary>删除自动更新时改名留下的旧 exe（NotiBridge.exe.old-*）。</summary>
    public static void CleanupReplacedFiles()
    {
        try
        {
            var dir = Path.GetDirectoryName(Environment.ProcessPath ?? "");
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
            foreach (var f in Directory.GetFiles(dir, "NotiBridge.exe.old-*"))
            {
                try { File.Delete(f); } catch (Exception) { }
            }
        }
        catch (Exception)
        {
        }
    }

    private static bool AutoStartPointsTo(string exe)
    {
        using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return k?.GetValue("NotiBridge") is string s && s.Contains(exe, StringComparison.OrdinalIgnoreCase);
    }

    private static void RegisterUninstall()
    {
        using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
        var v = CurrentVersion;
        k.SetValue("DisplayName", "NotiBridge");
        k.SetValue("DisplayVersion", $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}");
        k.SetValue("Publisher", "NotiBridge");
        k.SetValue("DisplayIcon", $"\"{InstalledExe}\",0");
        k.SetValue("InstallLocation", InstallDir);
        k.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
        k.SetValue("QuietUninstallString", $"\"{InstalledExe}\" --uninstall --quiet");
        k.SetValue("URLInfoAbout", "https://github.com/Allen-1002/NotiBridge");
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
            sc.Description = "把手机通知同步到 Windows";
            sc.Save();
        }
        catch (Exception)
        {
            // 快捷方式失败不影响使用
        }
    }

    /// <summary>卸载前的确认框。</summary>
    public static bool ConfirmUninstall(Window? owner)
    {
        const string text = "确定要卸载 NotiBridge 吗？\n\n将退出程序，并移除开机启动、通知注册、快捷方式和“已安装的应用”中的条目。";
        var r = owner is null
            ? MessageBox.Show(text, "卸载 NotiBridge", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No)
            : MessageBox.Show(owner, text, "卸载 NotiBridge", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
        return r == MessageBoxResult.Yes;
    }

    private static string AppDataDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppName);
    private static string LocalDataDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);

    /// <summary>
    /// 清除所有数据：关闭开机启动，清空通知中心里的 NotiBridge 通知，
    /// 删除 %APPDATA%\NotiBridge（settings.json、DPAPI 加密的 paired.json 配对密钥）和 %LOCALAPPDATA%\NotiBridge（缓存）。
    /// 调用前应先停止服务，避免程序退出时又写回设置。
    /// </summary>
    public static void ClearAllData()
    {
        try { AutoStart.Set(false); }
        catch (Exception) { }
        Notifier.ClearHistory();
        TryDeleteDir(AppDataDir);
        TryDeleteDir(LocalDataDir);
    }

    /// <summary>
    /// 卸载（从“已安装的应用”、程序设置或 NotiBridge.exe --uninstall 调用）：
    /// 退出正在运行的 NotiBridge，删除快捷方式、开机启动项、通知注册、卸载项和程序文件；默认同时删除配对和设置数据。
    /// 免安装运行时同样清理，并提示用户自行删除 exe。
    /// </summary>
    public static void RunUninstall(bool quiet, bool askConfirm = true)
    {
        var portableExe = IsRunningInstalled ? null : Environment.ProcessPath;
        if (!quiet && askConfirm)
        {
            if (!ConfirmUninstall(null)) return;
        }
        StopOtherInstances(null);
        AutoStart.Set(false);
        Notifier.ClearHistory();
        Notifier.Uninstall();
        TryDelete(StartMenuLink);
        TryDelete(DesktopLink);
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); }
        catch (Exception) { }

        // 默认删除数据；静默卸载也删除
        var deleteData = true;
        if (!quiet)
        {
            var data = MessageBox.Show("同时删除设置和已配对手机的密钥吗？（推荐）\n\n选“否”则保留，重新安装后不用重新配对。",
                "卸载 NotiBridge", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.Yes);
            deleteData = data != MessageBoxResult.No;
        }
        if (deleteData)
        {
            TryDeleteDir(AppDataDir);
            TryDeleteDir(LocalDataDir);
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
        if (quiet) return;
        if (portableExe is not null)
        {
            var open = MessageBox.Show($"NotiBridge 已卸载{(deleteData ? "，数据已删除" : "")}。\n\n" +
                                       $"当前是免安装运行的 exe，请在程序退出后手动删除它：\n{portableExe}\n\n要在文件资源管理器中显示它吗？",
                "卸载 NotiBridge", MessageBoxButton.YesNo, MessageBoxImage.Information);
            if (open == MessageBoxResult.Yes)
            {
                try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{portableExe}\"") { UseShellExecute = true }); }
                catch (Exception) { }
            }
        }
        else
        {
            MessageBox.Show($"NotiBridge 已卸载{(deleteData ? "，数据已删除" : "")}。", "卸载 NotiBridge", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private static void StopOtherInstances(string? onlyPath)
    {
        var me = Environment.ProcessId;
        foreach (var p in Process.GetProcessesByName("NotiBridge"))
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
