using System.Reflection;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace HarmoBridge.Windows;

/// <summary>系统托盘图标（对应 Mac 菜单栏图标）：显示状态、快速暂停同步、配对新手机。</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly AppModel _model;
    private readonly Forms.ToolStripMenuItem _status;
    private readonly Forms.ToolStripMenuItem _pause;
    private readonly Drawing.Icon _normal;
    private readonly Drawing.Icon _paused;

    public TrayIcon(AppModel model, Action showMain, Action quit)
    {
        _model = model;
        using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("HarmoBridge.ico")!)
            _normal = new Drawing.Icon(s, Forms.SystemInformation.SmallIconSize);
        _paused = MakePausedIcon(_normal);

        _status = new Forms.ToolStripMenuItem { Enabled = false };
        _pause = new Forms.ToolStripMenuItem("暂停同步") { CheckOnClick = false };
        _pause.Click += (_, _) => _model.Paused = !_model.Paused;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(_status);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("打开主窗口", null, (_, _) => showMain());
        menu.Items.Add("配对新手机", null, (_, _) =>
        {
            _model.OpenPairing();
            showMain();
        });
        menu.Items.Add(_pause);
        menu.Items.Add("复制最近的验证码", null, (_, _) => _model.CopyLastOtp());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出 HarmoBridge", null, (_, _) => quit());
        menu.Opening += (_, _) => Refresh();

        _icon = new Forms.NotifyIcon { Icon = _normal, ContextMenuStrip = menu, Visible = true };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) showMain();
        };
        _model.StatusChanged += Refresh;
        Refresh();
    }

    private void Refresh()
    {
        var text = _model.TrayText;
        _icon.Text = text.Length > 63 ? text[..63] : text; // 托盘提示最多 63 字符
        _icon.Icon = _model.Paused ? _paused : _normal;
        _status.Text = _model.Headline;
        _pause.Checked = _model.Paused;
    }

    private static Drawing.Icon MakePausedIcon(Drawing.Icon baseIcon)
    {
        using var bmp = baseIcon.ToBitmap();
        using (var g = Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var r = bmp.Width / 2f;
            g.FillEllipse(Drawing.Brushes.Gray, bmp.Width - r, bmp.Height - r, r, r);
        }
        return Drawing.Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
