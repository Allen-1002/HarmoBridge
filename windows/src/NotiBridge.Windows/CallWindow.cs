using System.ComponentModel;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using NotiBridge.Core;

namespace NotiBridge.Windows;

/// <summary>电脑上的联系人：从手机导出的 .vcf / CSV 导入，用 DPAPI 加密保存在本机（只有当前 Windows 用户能读）。</summary>
public sealed class ContactsStore
{
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NotiBridge", "contacts.bin");

    public ContactIndex Index { get; private set; } = new();
    public int Count => Index.Entries.Count;
    public event Action? Changed;

    public ContactsStore()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), null, DataProtectionScope.CurrentUser);
                Index = new ContactIndex(JsonSerializer.Deserialize<List<ContactEntry>>(json) ?? []);
            }
        }
        catch (Exception) { }
    }

    /// <summary>导入文件（覆盖原有联系人），返回导入的号码数</summary>
    public int Import(string path)
    {
        var text = File.ReadAllText(path, Encoding.UTF8);
        var list = path.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) ? ContactImport.ParseCsv(text) : ContactImport.ParseVcf(text);
        Index = new ContactIndex(list);
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllBytes(FilePath, ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(Index.Entries), null, DataProtectionScope.CurrentUser));
        Changed?.Invoke();
        return Index.Entries.Count;
    }

    public void Clear()
    {
        Index = new ContactIndex();
        try { File.Delete(FilePath); } catch (Exception) { }
        Changed?.Invoke();
    }

    public string? NameFor(string number) => number.Length == 0 ? null : Index.NameFor(number);
}

/// <summary>当前通话在界面上的状态（通话小窗、主窗口横条共用）</summary>
public sealed class CallSession : ObservableObject
{
    private readonly Esp32Manager _esp;
    private readonly ContactsStore _contacts;
    private PhoneCall _call = PhoneCall.Idle;
    private DateTime? _startedAt;
    private bool _compact;

    public CallSession(Esp32Manager esp, ContactsStore contacts)
    {
        _esp = esp;
        _contacts = contacts;
        esp.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Esp32Manager.Call)) Update(esp.Call);
            if (e.PropertyName is nameof(Esp32Manager.Hfp) or nameof(Esp32Manager.Muted)) Raise(nameof(AudioOnPC));
        };
    }

    public PhoneCall Call { get => _call; private set => Set(ref _call, value); }
    public DateTime? StartedAt => _startedAt;
    public bool IsIdle => _call.IsIdle;
    public bool AudioOnPC => _esp.Hfp?.AudioToPC == true;
    public bool Muted { get => _esp.Muted; set { _esp.Muted = value; Raise(); } }
    public bool Compact { get => _compact; set => Set(ref _compact, value); }

    public string? ContactName => _call.Number.Length == 0 ? null : _contacts.NameFor(_call.Number);
    public string Title => ContactName ?? (_call.Number.Length == 0 ? "未知号码" : _call.Number);
    public string Subtitle
    {
        get
        {
            var st = _call.State switch
            {
                "incoming" => "来电",
                "dialing" => "正在呼叫…",
                "alerting" => "对方振铃中…",
                "active" => _call.Held > 0 ? "通话保持中" : "通话中",
                _ => "",
            };
            return ContactName is not null && _call.Number.Length > 0 ? $"{_call.Number} · {st}" : st;
        }
    }

    private void Update(PhoneCall c)
    {
        var wasIdle = _call.IsIdle;
        if (c.State == "active" && _startedAt is null) _startedAt = DateTime.Now;
        if (c.IsIdle) { _startedAt = null; Compact = false; if (_esp.Muted) _esp.Muted = false; }
        if (wasIdle && !c.IsIdle) Compact = false;
        Call = c;
        Raise(nameof(IsIdle));
        Raise(nameof(Title));
        Raise(nameof(Subtitle));
    }

    public string Duration => _startedAt is { } t ? (DateTime.Now - t).ToString(@"mm\:ss") : "";

    public void Answer() => _esp.Answer();
    public void HangUp() => _esp.HangUp();
    public void ToggleAudio() => _esp.SetAudioToPC(!AudioOnPC);
    public void Dtmf(char c) => _esp.SendDtmf(c);
}

/// <summary>通话控制条：来电时“接听/拒接”，通话中“静音/切换声音/键盘/挂断”。小窗和主窗口横条共用。</summary>
public sealed class CallBar : Border
{
    private readonly CallSession _s;
    private readonly TextBlock _title = new() { FontSize = 16, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock _sub = new() { FontSize = 12, Opacity = 0.75 };
    private readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
    private readonly UniformGrid _pad = new() { Columns = 3, Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
    private readonly Button _collapse = new() { Content = "—", Width = 28, Height = 24, ToolTip = "收起" };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    public bool ShowCollapse { get; init; }

    public CallBar(CallSession s)
    {
        _s = s;
        Padding = new Thickness(14);
        CornerRadius = new CornerRadius(12);
        Background = new SolidColorBrush(Color.FromArgb(0x26, 0x16, 0xA3, 0x4A));
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x80, 0x16, 0xA3, 0x4A));
        BorderThickness = new Thickness(1);
        var top = new DockPanel();
        _collapse.Click += (_, _) => _s.Compact = true;
        DockPanel.SetDock(_collapse, Dock.Right);
        top.Children.Add(_collapse);
        var text = new StackPanel();
        text.Children.Add(_title);
        text.Children.Add(_sub);
        top.Children.Add(text);
        var root = new StackPanel();
        root.Children.Add(top);
        root.Children.Add(_buttons);
        root.Children.Add(_pad);
        foreach (var k in "123456789*0#")
        {
            var b = new Button { Content = k.ToString(), Height = 30, Margin = new Thickness(2), FontSize = 15 };
            b.Click += (_, _) => _s.Dtmf(k);
            _pad.Children.Add(b);
        }
        Child = root;
        s.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        _timer.Tick += (_, _) => _sub.Text = Sub();
        _timer.Start();
        Refresh();
    }

    private string Sub() => _s.Duration.Length > 0 ? $"{_s.Subtitle}  {_s.Duration}" : _s.Subtitle;

    private Button Btn(string text, Action a, Brush? bg = null)
    {
        var b = new Button { Content = text, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(0, 0, 8, 0) };
        if (bg is not null) { b.Background = bg; b.Foreground = Brushes.White; }
        b.Click += (_, _) => a();
        return b;
    }

    private void Refresh()
    {
        _title.Text = _s.Title;
        _sub.Text = Sub();
        _collapse.Visibility = ShowCollapse && _s.Call.State != "incoming" ? Visibility.Visible : Visibility.Collapsed;
        _buttons.Children.Clear();
        var green = new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A));
        var red = new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26));
        if (_s.Call.State == "incoming")
        {
            _buttons.Children.Add(Btn("接听", _s.Answer, green));
            _buttons.Children.Add(Btn("拒接", _s.HangUp, red));
            _pad.Visibility = Visibility.Collapsed;
        }
        else
        {
            var mute = Btn(_s.Muted ? "取消静音" : "静音", () => _s.Muted = !_s.Muted);
            mute.IsEnabled = _s.AudioOnPC;
            _buttons.Children.Add(mute);
            _buttons.Children.Add(Btn(_s.AudioOnPC ? "切回手机" : "切到电脑", _s.ToggleAudio));
            _buttons.Children.Add(Btn("键盘", () => _pad.Visibility = _pad.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible));
            _buttons.Children.Add(Btn("挂断", _s.HangUp, red));
        }
    }
}

/// <summary>来电/通话小窗：屏幕右上角、置顶、不出现在任务栏、可拖动、可收成胶囊，电话结束才消失。</summary>
public sealed class CallWindow : Window
{
    private readonly CallSession _s;
    private readonly CallBar _bar;
    private readonly Border _pill;
    private readonly TextBlock _pillText = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _placed;

    public CallWindow(CallSession s)
    {
        _s = s;
        Title = "NotiBridge 通话";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        _bar = new CallBar(s) { ShowCollapse = true, Width = 320, Background = SystemColors.WindowBrush };
        var hang = new Button { Content = "挂断", Padding = new Thickness(10, 3, 10, 3) };
        hang.Click += (_, _) => s.HangUp();
        var pillRow = new StackPanel { Orientation = Orientation.Horizontal };
        pillRow.Children.Add(_pillText);
        pillRow.Children.Add(hang);
        _pill = new Border
        {
            Child = pillRow, CornerRadius = new CornerRadius(18), Padding = new Thickness(14, 6, 8, 6),
            Background = SystemColors.WindowBrush, BorderBrush = Brushes.SeaGreen, BorderThickness = new Thickness(1),
        };
        _pill.MouseLeftButtonUp += (_, _) => s.Compact = false;
        MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) try { DragMove(); } catch (InvalidOperationException) { } };
        s.PropertyChanged += OnSession;
        _timer.Tick += (_, _) => _pillText.Text = $"📞 {_s.Title}  {_s.Duration}";
        _timer.Start();
        Apply();
    }

    private void OnSession(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Apply);

    private void Apply()
    {
        if (_s.IsIdle) { Hide(); _placed = false; return; }
        Content = _s.Compact ? _pill : _bar;
        _pillText.Text = $"📞 {_s.Title}  {_s.Duration}";
        if (!IsVisible) Show();
        if (!_placed)
        {
            UpdateLayout();
            var wa = SystemParameters.WorkArea;
            Left = wa.Right - ActualWidth - 16;
            Top = wa.Top + 16;
            _placed = true;
        }
    }
}
