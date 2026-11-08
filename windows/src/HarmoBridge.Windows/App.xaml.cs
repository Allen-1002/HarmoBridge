using System.IO;
using System.Threading;
using System.Windows;

namespace HarmoBridge.Windows;

public partial class App : Application
{
    private const string MutexName = @"Local\HarmoBridge.Windows.Instance";
    private const string ShowEventName = @"Local\HarmoBridge.Windows.Show";

    private Mutex? _mutex;
    private EventWaitHandle? _showEvent;
    private TrayIcon? _tray;
    private MainWindow? _main;

    public AppModel Model { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--uninstall"))
        {
            Notifier.Uninstall();
            AutoStart.Set(false);
            Shutdown();
            return;
        }

        // 单实例：再次启动时只把已运行的窗口叫出来
        _mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            try { EventWaitHandle.OpenExisting(ShowEventName).Set(); }
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

        DispatcherUnhandledException += (_, ex) =>
        {
            Model?.Log($"程序错误：{ex.Exception.Message}");
            WriteCrash(ex.Exception);
            ex.Handled = true;
        };

        Model = new AppModel();
        Model.ShowWindowRequested += ShowMain;
        _tray = new TrayIcon(Model, ShowMain, Quit);
        Model.Start();

        var background = e.Args.Contains("--background");
        if (!Model.Onboarded || !background) ShowMain();
    }

    public void ShowMain()
    {
        if (_main is null)
        {
            _main = new MainWindow(Model);
            _main.Closed += (_, _) => _main = null;
        }
        _main.Show();
        if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
        _main.Activate();
    }

    public void Quit()
    {
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
