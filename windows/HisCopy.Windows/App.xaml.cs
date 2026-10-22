using System.Windows;
using HisCopy.Windows.Services;
using HisCopy.Windows.Views;
using Application = System.Windows.Application;
using MessageBox = System.Windows.MessageBox;

namespace HisCopy.Windows;

public partial class App : Application
{
    private TrayService? _tray;
    private ClipboardMonitor? _monitor;
    private HotKeyService? _hotKey;
    private HistoryWindow? _historyWindow;
    private readonly ClipboardHistoryStore _store = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _store.Load();
        _historyWindow = new HistoryWindow(_store);
        _historyWindow.PasteRequested += OnPasteRequested;

        _monitor = new ClipboardMonitor(_store);
        _monitor.Start();

        _tray = new TrayService();
        _tray.ShowHistoryRequested += (_, _) => ToggleHistory();
        _tray.ExitRequested += (_, _) => Shutdown();
        _tray.CheckUpdateRequested += async (_, _) => await CheckUpdateAsync();

        _hotKey = new HotKeyService();
        // Ctrl+Shift+V — Windows counterpart of ⇧⌘V
        if (!_hotKey.Register(Modifiers.Control | Modifiers.Shift, KeyCode.V, ToggleHistory))
        {
            MessageBox.Show(
                "无法注册全局快捷键 Ctrl+Shift+V，可能被其它程序占用。仍可从托盘图标打开历史。",
                "HisCopy",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void ToggleHistory()
    {
        if (_historyWindow == null) return;
        if (_historyWindow.IsVisible)
            _historyWindow.HidePanel();
        else
            _historyWindow.ShowCentered();
    }

    private void OnPasteRequested(object? sender, PasteRequest e)
    {
        _historyWindow?.HidePanel();
        // Defer so the panel releases activation before SendInput
        Dispatcher.BeginInvoke(async () =>
        {
            await Task.Delay(80);
            PasteService.Paste(e.Item, e.PlainTextOnly);
        });
    }

    private async Task CheckUpdateAsync()
    {
        try
        {
            var result = await UpdateChecker.CheckAsync("BianYanhui", "HisCopy", "0.1.0");
            if (result == null)
            {
                _tray?.ShowBalloon("HisCopy", "已是最新版本（Windows）。");
                return;
            }
            var open = MessageBox.Show(
                $"发现新版本 {result.Tag}:\n{result.Name}\n\n打开 Release 页面？",
                "HisCopy 更新",
                MessageBoxButton.YesNo,
                MessageBoxImage.Information);
            if (open == MessageBoxResult.Yes)
                UpdateChecker.OpenInBrowser(result.HtmlUrl);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"检查更新失败：{ex.Message}", "HisCopy");
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotKey?.Dispose();
        _monitor?.Dispose();
        _tray?.Dispose();
        _store.Save();
        base.OnExit(e);
    }
}
