using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Threading;
using NotiBridge.Core;

namespace NotiBridge.Windows;

/// <summary>
/// 自动更新：从 GitHub Releases 检查新版本，下载 zip、校验 SHA256、解压出 NotiBridge.exe 并核对文件版本，
/// 然后启动新 exe 的 <c>--apply-update &lt;旧进程 PID&gt; &lt;目标路径&gt;</c>：它等旧进程退出，把自己复制到目标位置，
/// 再以 <c>--background --updated &lt;版本&gt;</c> 启动新版。HttpClient 下载的文件没有“网络标记”，不会触发 SmartScreen。
/// </summary>
public sealed class Updater : ObservableObject
{
    private static readonly TimeSpan FirstCheckDelay = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(6);

    private readonly AppSettings _settings;
    private readonly Action<string> _log;
    private readonly DispatcherTimer _timer = new();
    private readonly DispatcherTimer _retry = new() { Interval = TimeSpan.FromMinutes(1) };
    private UpdateCore.Release? _available;
    private string _status = "尚未检查";
    private string? _latestVersion;
    private string _notes = "";
    private double _progress;
    private bool _progressVisible;
    private bool _busy;
    private bool _failed;
    private bool _notifiedAvailable;
    private string _progressText = "";
    /// <summary>已下载、校验并解压好的新版（等用户点“重启并安装”）</summary>
    private (string Exe, string Work, string Version)? _staged;

    /// <summary>返回 false 表示现在不适合更新（例如正在配对手机）</summary>
    public Func<bool> CanUpdateNow { get; set; } = () => true;
    /// <summary>显示一条本机通知（标题，正文）</summary>
    public Action<string, string> ShowToast { get; set; } = (_, _) => { };

    public Updater(AppSettings settings, Action<string> log)
    {
        _settings = settings;
        _log = log;
        _timer.Tick += (_, _) =>
        {
            if (_timer.Interval != CheckInterval)
            {
                // 首次（启动 30 秒后）：之后每 6 小时一次；顺便清理上次更新留下的文件
                _timer.Interval = CheckInterval;
                if (_staged is null && !IsBusy) CleanupUpdateDir();
            }
            if (AutoCheck) _ = CheckAsync(manual: false);
        };
        _retry.Tick += (_, _) =>
        {
            _retry.Stop();
            ApplyStaged();
        };
    }

    public static string CurrentVersion
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);
            return $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
        }
    }

    public static string UpdateDir => Path.Combine(Paths.CacheDir, "update");
    private static string ApplyLog => Path.Combine(Paths.CacheDir, "update-apply.log");

    public void Start(string? updatedTo)
    {
        if (updatedTo is not null)
        {
            if (UpdateCore.CompareVersions(updatedTo, CurrentVersion) == 0)
            {
                Status = $"已更新到 {CurrentVersion}";
                Log($"已更新到 {CurrentVersion}");
                ShowToast($"已更新到 {CurrentVersion}", "NotiBridge 已自动更新并重新启动。");
            }
            else
            {
                Log($"自动更新到 {updatedTo} 未完成，当前仍是 {CurrentVersion}，详情见 {ApplyLog}");
                Status = "上次更新未完成，可以再试一次";
            }
        }
        _timer.Interval = FirstCheckDelay;
        _timer.Start();
    }

    // ---------------- 状态 ----------------

    public bool AutoCheck
    {
        get => _settings.UpdateAutoCheck;
        set
        {
            if (_settings.UpdateAutoCheck == value) return;
            _settings.UpdateAutoCheck = value;
            _settings.Save();
            Raise();
        }
    }

    public bool AutoInstall
    {
        get => _settings.UpdateAutoInstall;
        set
        {
            if (_settings.UpdateAutoInstall == value) return;
            _settings.UpdateAutoInstall = value;
            _settings.Save();
            Raise();
        }
    }

    public string CurrentVersionText => CurrentVersion;
    public string LatestVersionText => _latestVersion ?? "未知";

    public string Status
    {
        get => _status;
        private set => Set(ref _status, value);
    }

    public string Notes
    {
        get => _notes;
        private set => Set(ref _notes, value);
    }

    public double Progress
    {
        get => _progress;
        private set => Set(ref _progress, value);
    }

    /// <summary>已下载 / 总大小</summary>
    public string ProgressText
    {
        get => _progressText;
        private set => Set(ref _progressText, value);
    }

    public bool ProgressVisible
    {
        get => _progressVisible;
        private set => Set(ref _progressVisible, value);
    }

    public bool IsBusy
    {
        get => _busy;
        private set
        {
            if (Set(ref _busy, value)) Raise(nameof(IsIdle));
        }
    }

    public bool IsIdle => !_busy;
    public bool HasUpdate => _available is not null;
    public bool Failed
    {
        get => _failed;
        private set => Set(ref _failed, value);
    }

    public bool IsReady => _staged is { } st && _available is { } a && st.Version == a.Version;
    public string InstallButtonText => _available is null ? "下载新版本"
        : IsReady ? $"重启并安装 {_available.Version}" : $"下载 {_available.Version}";
    public string? ReleasePage => _available?.HtmlUrl;

    private void SetAvailable(UpdateCore.Release? r)
    {
        _available = r;
        Raise(nameof(HasUpdate));
        Raise(nameof(InstallButtonText));
        Raise(nameof(ReleasePage));
        Raise(nameof(IsReady));
    }

    // ---------------- 检查 ----------------

    private static HttpClient NewClient(TimeSpan timeout)
    {
        var c = new HttpClient { Timeout = timeout };
        c.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue(UpdateCore.UserAgent, CurrentVersion));
        return c;
    }

    public async Task CheckAsync(bool manual)
    {
        if (IsBusy) return;
        IsBusy = true;
        Failed = false;
        Status = "正在检查更新…";
        Log($"检查更新：{UpdateCore.LatestReleaseUrl}（当前 {CurrentVersion}）");
        UpdateCore.Release release;
        try
        {
            using var http = NewClient(TimeSpan.FromSeconds(30));
            using var req = new HttpRequestMessage(HttpMethod.Get, UpdateCore.LatestReleaseUrl);
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var resp = await http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) throw new InvalidOperationException($"GitHub 返回 HTTP {(int)resp.StatusCode}");
            release = UpdateCore.ParseRelease(await resp.Content.ReadAsStringAsync());
            if (release.Draft || release.Prerelease) throw new InvalidOperationException("最新 Release 是草稿或预发布版本，已忽略");
        }
        catch (Exception ex)
        {
            IsBusy = false;
            Fail($"检查更新失败：{ex.Message}");
            return;
        }
        _latestVersion = release.Version;
        Raise(nameof(LatestVersionText));
        Notes = release.NotesSnippet();
        if (!UpdateCore.IsNewer(release.Version, CurrentVersion))
        {
            SetAvailable(null);
            IsBusy = false;
            Status = "已是最新版本";
            Log($"已是最新版本（最新 {release.Version}）");
            return;
        }
        SetAvailable(release);
        Log($"发现新版本 {release.Version}");
        IsBusy = false;
        if (IsReady)
        {
            Status = $"{release.Version} 已下载，重启即可安装";
        }
        else if (AutoInstall && !manual)
        {
            // 后台自动更新：下载、校验后直接安装并重新启动
            if (await DownloadAvailableAsync()) ApplyStaged();
        }
        else
        {
            // 手动检查只检查，由用户决定是否下载
            Status = $"有新版本 {release.Version}，可以下载";
            if (!_notifiedAvailable && !manual)
            {
                _notifiedAvailable = true;
                ShowToast($"NotiBridge {release.Version} 可以更新了", "打开 设置 > 软件更新，点“下载”。");
            }
        }
    }

    // ---------------- 下载、校验、安装 ----------------

    /// <summary>界面上的主按钮：没下载就下载；下载好了就重启安装。</summary>
    public async Task PrimaryActionAsync()
    {
        if (IsReady) ApplyStaged();
        else await DownloadAvailableAsync();
    }

    /// <summary>下载、校验、解压新版，不重启。成功返回 true。</summary>
    public async Task<bool> DownloadAvailableAsync()
    {
        if (IsBusy || _available is null) return false;
        var release = _available;
        IsBusy = true;
        Failed = false;
        var version = release.Version;
        var zipName = UpdateCore.WindowsAssetName(version);
        try
        {
            var zipAsset = release.AssetNamed(zipName) ?? throw new InvalidOperationException($"Release 中没有 {zipName}");
            var sumsAsset = release.AssetNamed(UpdateCore.SumsAssetName)
                            ?? throw new InvalidOperationException($"Release 中没有 {UpdateCore.SumsAssetName}，无法校验，已取消");
            var work = Path.Combine(UpdateDir, version);
            TryDeleteDir(work);
            Directory.CreateDirectory(work);

            using var http = NewClient(TimeSpan.FromMinutes(30));

            // 1. 校验值
            Status = "正在下载校验值…";
            Log($"下载 {sumsAsset.BrowserDownloadUrl}");
            var sumsBytes = await http.GetByteArrayAsync(sumsAsset.BrowserDownloadUrl);
            // 1.1.0 起：先验证发布者的 Ed25519 签名，再信任校验值
            var sigAsset = release.AssetNamed(UpdateCore.SumsSignatureAssetName)
                           ?? throw new InvalidOperationException($"Release 中没有签名文件 {UpdateCore.SumsSignatureAssetName}，无法确认来源，已取消");
            var sigBytes = await http.GetByteArrayAsync(sigAsset.BrowserDownloadUrl);
            if (!UpdateCore.VerifySumsSignature(sumsBytes, sigBytes))
                throw new InvalidOperationException("发布签名校验失败：校验值不是由 NotiBridge 发布者签名的，已取消");
            Log("发布签名校验通过");
            var sums = UpdateCore.ParseSha256Sums(System.Text.Encoding.UTF8.GetString(sumsBytes));
            if (!sums.TryGetValue(zipName, out var expected))
                throw new InvalidOperationException($"SHA256SUMS.txt 中没有 {zipName}，已取消");

            // 2. 安装包
            Status = $"正在下载 {version}…";
            Log($"下载 {zipAsset.BrowserDownloadUrl}（{zipAsset.Size / 1024} KB）");
            var zipPath = Path.Combine(work, zipName);
            await DownloadAsync(http, zipAsset.BrowserDownloadUrl, zipPath, zipAsset.Size);

            // 3. 哈希
            Status = "正在校验…";
            string actual;
            await using (var fs = File.OpenRead(zipPath))
                actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(fs));
            if (actual != expected)
            {
                TryDelete(zipPath);
                throw new InvalidOperationException($"SHA256 不一致（期望 {expected[..12]}…，实际 {actual[..12]}…），已删除下载的文件");
            }
            Log($"SHA256 校验通过：{actual}");

            // 4. 解压 NotiBridge.exe 并核对版本
            var newExe = Path.Combine(work, "NotiBridge.exe");
            await Task.Run(() =>
            {
                using var zip = ZipFile.OpenRead(zipPath);
                var entry = zip.Entries.FirstOrDefault(e => e.Name.Equals("NotiBridge.exe", StringComparison.OrdinalIgnoreCase))
                            ?? throw new InvalidOperationException("zip 里没有 NotiBridge.exe");
                entry.ExtractToFile(newExe, true);
            });
            TryDelete(zipPath);
            var fv = FileVersionInfo.GetVersionInfo(newExe);
            var exeVersion = $"{fv.FileMajorPart}.{fv.FileMinorPart}.{fv.FileBuildPart}";
            if (UpdateCore.CompareVersions(exeVersion, version) != 0)
                throw new InvalidOperationException($"新版文件版本不对（{exeVersion}，期望 {version}），已取消");
            if (!string.Equals(fv.ProductName, "NotiBridge", StringComparison.Ordinal))
                throw new InvalidOperationException($"新版产品名不对（{fv.ProductName}），已取消");
            Log($"已解压并核对版本 {exeVersion}");

            _staged = (newExe, work, version);
            Raise(nameof(IsReady));
            Raise(nameof(InstallButtonText));
            IsBusy = false;
            Status = $"{version} 已下载并校验通过，重启即可安装";
            return true;
        }
        catch (Exception ex)
        {
            ProgressVisible = false;
            IsBusy = false;
            Fail($"下载更新失败：{ex.Message}");
            return false;
        }
    }

    /// <summary>交给新 exe 替换并重启。</summary>
    public void ApplyStaged()
    {
        if (IsBusy || _staged is not { } st) return;
        if (!CanUpdateNow())
        {
            Status = $"{st.Version} 已下载，配对结束后再安装";
            Log("正在配对手机，1 分钟后再尝试安装");
            _retry.Start();
            return;
        }
        try
        {
            var target = Environment.ProcessPath ?? throw new InvalidOperationException("找不到当前程序路径");
            IsBusy = true;
            Status = $"正在安装 {st.Version}，即将重新启动…";
            Log($"启动更新程序，替换 {target}");
            Process.Start(new ProcessStartInfo(st.Exe)
            {
                UseShellExecute = false,
                ArgumentList = { "--apply-update", Environment.ProcessId.ToString(), target },
                WorkingDirectory = st.Work,
            });
            ((App)Application.Current).QuitForUpdate();
        }
        catch (Exception ex)
        {
            IsBusy = false;
            Fail($"安装失败：{ex.Message}");
        }
    }

    private async Task DownloadAsync(HttpClient http, string url, string dest, long expectedSize)
    {
        Progress = 0;
        ProgressVisible = true;
        using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        resp.EnsureSuccessStatusCode();
        var total = resp.Content.Headers.ContentLength ?? expectedSize;
        await using (var src = await resp.Content.ReadAsStreamAsync())
        await using (var dst = File.Create(dest))
        {
            var buf = new byte[1 << 16];
            long done = 0;
            int n;
            var lastPct = -1;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n));
                done += n;
                if (total > 0)
                {
                    var pct = (int)(done * 100 / total);
                    if (pct != lastPct)
                    {
                        lastPct = pct;
                        Progress = pct;
                        ProgressText = $"{pct}%  {done / 1048576.0:0.0} MB / {total / 1048576.0:0.0} MB";
                    }
                }
            }
        }
        ProgressVisible = false;
        ProgressText = "";
        var size = new FileInfo(dest).Length;
        if (expectedSize > 0 && size != expectedSize)
            throw new InvalidOperationException($"下载的文件大小不对（{size} / {expectedSize} 字节）");
    }

    private void Fail(string message)
    {
        Failed = true;
        Status = message;
        Log(message);
    }

    private void Log(string s) => _log("[更新] " + s);

    /// <summary>删除旧的下载目录（新版启动 30 秒后执行，那时 --apply-update 进程早已退出）。</summary>
    private static void CleanupUpdateDir()
    {
        try
        {
            if (!Directory.Exists(UpdateDir)) return;
            foreach (var d in Directory.GetDirectories(UpdateDir)) TryDeleteDir(d);
            foreach (var f in Directory.GetFiles(UpdateDir)) TryDelete(f);
        }
        catch (Exception)
        {
        }
    }

    // ---------------- --apply-update（在新 exe 里运行，早于单实例锁） ----------------

    /// <summary>
    /// NotiBridge.exe --apply-update &lt;旧进程 PID&gt; &lt;目标 exe 路径&gt;：
    /// 等旧进程退出（最多 30 秒），把自己复制到目标路径（已安装的那份走 Installer.Install，同时刷新“已安装的应用”里的版本号），
    /// 然后启动目标 exe。失败时仍启动原来的程序，并提示。
    /// </summary>
    public static void RunApplyUpdate(string[] args)
    {
        var i = Array.IndexOf(args, "--apply-update");
        var pidText = i + 1 < args.Length ? args[i + 1] : "";
        var target = i + 2 < args.Length ? args[i + 2] : "";
        var self = Environment.ProcessPath ?? "";
        ApplyLogLine($"apply-update pid={pidText} target={target} self={self} version={CurrentVersion}");
        if (!int.TryParse(pidText, out var pid) || string.IsNullOrWhiteSpace(target) || self.Length == 0)
        {
            ApplyLogLine("参数不对，放弃");
            return;
        }
        try
        {
            using var old = Process.GetProcessById(pid);
            if (!old.WaitForExit(10_000))
            {
                ApplyLogLine("旧进程 10 秒内没有退出，强制结束");
                try { old.Kill(); old.WaitForExit(5000); }
                catch (Exception) { }
            }
        }
        catch (ArgumentException)
        {
            // 已经退出
        }

        var ok = false;
        try
        {
            var fullTarget = Path.GetFullPath(target);
            if (string.Equals(fullTarget, Path.GetFullPath(Installer.InstalledExe), StringComparison.OrdinalIgnoreCase))
            {
                Installer.Install(); // 复制自己到安装目录、刷新快捷方式和卸载项版本号
            }
            else
            {
                Installer.ReplaceFile(self, fullTarget);
            }
            ok = true;
            ApplyLogLine("替换完成");
        }
        catch (Exception ex)
        {
            ApplyLogLine($"替换失败：{ex}");
            // DefaultDesktopOnly：提示框显示在最前面，不会藏在其他窗口后面只在任务栏留一个图标
            MessageBox.Show($"NotiBridge 自动更新失败：{ex.Message}\n\n将继续运行原来的版本。可以在 设置 > 软件更新 里重试，或从 GitHub 手动下载。\n详细记录：{ApplyLog}",
                "NotiBridge 更新", MessageBoxButton.OK, MessageBoxImage.Warning, MessageBoxResult.OK,
                MessageBoxOptions.DefaultDesktopOnly);
        }

        try
        {
            var psi = new ProcessStartInfo(target) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(target) ?? "" };
            psi.ArgumentList.Add("--background");
            psi.ArgumentList.Add("--updated");
            psi.ArgumentList.Add(ok ? CurrentVersion : "0.0.0");
            Process.Start(psi);
            ApplyLogLine("已启动新版");
        }
        catch (Exception ex)
        {
            ApplyLogLine($"启动失败：{ex.Message}");
        }
    }

    /// <summary>从命令行取 --updated 后的版本号</summary>
    public static string? UpdatedVersionArg(string[] args)
    {
        var i = Array.IndexOf(args, "--updated");
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static void ApplyLogLine(string s)
    {
        try { File.AppendAllText(ApplyLog, $"{DateTime.Now:O} {s}\n"); }
        catch (Exception) { }
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
