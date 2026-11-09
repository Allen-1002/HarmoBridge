using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Interop;

namespace NotiBridge.Windows;

public partial class App : Application
{
    private const string MutexName = @"Local\NotiBridge.Windows.Instance";
    private const string ShowEventName = @"Local\NotiBridge.Windows.Show";

    private Mutex? _mutex;
    private EventWaitHandle? _showEvent;
    private TrayIcon? _tray;
    private MainWindow? _main;
    private bool _quitting;

    // 已运行的实例从后台线程收到“显示窗口”信号时，Windows 的前台锁会阻止它把窗口切到前台；
    // 由第二个实例（用户刚点了快捷方式，拥有前台权限）先调用 AllowSetForegroundWindow 授权。
    private const int AsfwAny = -1;
    private const int SwRestore = 9;
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int processId);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);

    public AppModel Model { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // 自动更新：新版 exe 替换旧版后启动它（必须早于安装提示和单实例锁）
        if (e.Args.Contains("--apply-update"))
        {
            Updater.RunApplyUpdate(e.Args);
            Shutdown();
            return;
        }
        if (e.Args.Contains("--uninstall"))
        {
            Installer.RunUninstall(e.Args.Contains("--quiet"));
            Shutdown();
            return;
        }
        // 首次运行提示安装；已安装时转交给安装好的那份（或更新它）
        if (Installer.HandleStartup(AppSettings.Load(), e.Args))
        {
            Shutdown();
            return;
        }

        // 单实例：再次启动时只把已运行的窗口叫出来
        _mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            try
            {
                AllowSetForegroundWindow(AsfwAny);
                EventWaitHandle.OpenExisting(ShowEventName).Set();
            }
            catch (Exception) { }
            Shutdown();
            return;
        }
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        var t = new Thread(() =>
        {
            while (_showEvent.WaitOne())
                Dispatcher.BeginInvoke(ShowMain);
        }) { IsBackground = true };
        t.Start();

        SessionEnding += (_, _) => _quitting = true; // 注销/关机时不拦截窗口关闭
        DispatcherUnhandledException += (_, ex) =>
        {
            Model?.Log($"程序错误：{ex.Exception.Message}");
            WriteCrash(ex.Exception);
            ex.Handled = true;
        };

        Installer.CleanupReplacedFiles();
        Model = new AppModel();
        Model.ShowWindowRequested += ShowMain;
        _tray = new TrayIcon(Model, ShowMain, Quit);
        Model.Start(Updater.UpdatedVersionArg(e.Args));

        var background = e.Args.Contains("--background");
        if (!Model.Onboarded || !background) ShowMain();
    }

    public void ShowMain()
    {
        try
        {
            if (_main is null)
            {
                var w = new MainWindow(Model);
                // 关闭窗口只隐藏，程序留在托盘；下次点击托盘图标直接显示同一个窗口
                w.Closing += (_, ev) =>
                {
                    if (_quitting) return;
                    ev.Cancel = true;
                    w.Hide();
                };
                w.Closed += (_, _) => { if (ReferenceEquals(_main, w)) _main = null; };
                _main = w;
            }
            var win = _main;
            win.Show();
            if (win.WindowState == WindowState.Minimized) win.WindowState = WindowState.Normal;
            var hwnd = new WindowInteropHelper(win).Handle;
            if (hwnd != IntPtr.Zero && IsIconic(hwnd)) ShowWindow(hwnd, SwRestore);
            win.Activate();
            // 前台锁兜底：短暂置顶再取消，然后请求切到前台
            win.Topmost = true;
            win.Topmost = false;
            if (hwnd != IntPtr.Zero) SetForegroundWindow(hwnd);
            win.Focus();
            Model.Log("已打开主窗口");
        }
        catch (Exception ex)
        {
            // 之前这里的异常会被全局处理器吞掉，表现为“点击图标没反应”
            Model.Log($"打开主窗口失败：{ex.Message}");
            WriteCrash(ex);
            _main = null;
        }
    }

    /// <summary>退出当前进程并从指定位置重新启动（安装后使用）。</summary>
    public void RestartFrom(string exe)
    {
        ReleaseInstanceLock();
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe) { UseShellExecute = true }); }
        catch (Exception) { }
        Quit();
    }

    /// <summary>自动更新：已启动 --apply-update 进程，释放单实例锁并退出，让它替换程序文件。</summary>
    public void QuitForUpdate()
    {
        ReleaseInstanceLock();
        // 兜底：无论清理时卡在哪里，3 秒后强制结束进程，让更新程序可以替换文件
        new Thread(() =>
        {
            Thread.Sleep(3000);
            Environment.Exit(0);
        }) { IsBackground = true }.Start();
        try
        {
            Quit();
        }
        catch (Exception)
        {
            Environment.Exit(0);
        }
    }

    public void Uninstall()
    {
        ReleaseInstanceLock();
        _quitting = true;
        _tray?.Dispose();
        Model.Shutdown();
        Installer.RunUninstall(false, askConfirm: false);
        Shutdown();
    }

    /// <summary>清除所有数据后重新启动程序（回到首次引导）。</summary>
    public void ResetAllDataAndRestart()
    {
        ReleaseInstanceLock();
        _quitting = true;
        _tray?.Dispose();
        Model.Shutdown();
        Installer.ClearAllData();
        if (Environment.ProcessPath is { } exe)
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe) { UseShellExecute = true }); }
            catch (Exception) { }
        }
        Shutdown();
    }

    private void ReleaseInstanceLock()
    {
        try { _mutex?.ReleaseMutex(); }
        catch (Exception) { }
        _mutex?.Dispose();
        _mutex = null;
    }

    public void Quit()
    {
        _quitting = true;
        _tray?.Dispose();
        Model.Shutdown();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }

    private static void WriteCrash(Exception ex)
    {
        try
        {
            File.AppendAllText(Path.Combine(Paths.CacheDir, "error.log"), $"{DateTime.Now:O} {ex}\n\n");
        }
        catch (Exception)
        {
        }
    }
}
