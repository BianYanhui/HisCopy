using System.Drawing;
using System.Windows.Forms;

namespace HisCopy.Windows.Services;

public sealed class TrayService : IDisposable
{
    private readonly NotifyIcon _icon;

    public event EventHandler? ShowHistoryRequested;
    public event EventHandler? ExitRequested;
    public event EventHandler? CheckUpdateRequested;

    public TrayService()
    {
        _icon = new NotifyIcon
        {
            Text = "HisCopy",
            Visible = true,
            Icon = SystemIcons.Application
        };
        _icon.DoubleClick += (_, _) => ShowHistoryRequested?.Invoke(this, EventArgs.Empty);

        var menu = new ContextMenuStrip();
        menu.Items.Add("打开历史 (Ctrl+Shift+V)", null, (_, _) => ShowHistoryRequested?.Invoke(this, EventArgs.Empty));
        menu.Items.Add("检查更新…", null, (_, _) => CheckUpdateRequested?.Invoke(this, EventArgs.Empty));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => ExitRequested?.Invoke(this, EventArgs.Empty));
        _icon.ContextMenuStrip = menu;
    }

    public void ShowBalloon(string title, string text)
    {
        _icon.BalloonTipTitle = title;
        _icon.BalloonTipText = text;
        _icon.ShowBalloonTip(2500);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
