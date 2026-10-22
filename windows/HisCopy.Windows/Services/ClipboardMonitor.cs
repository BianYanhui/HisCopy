using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using HisCopy.Windows.Models;

namespace HisCopy.Windows.Services;

/// <summary>Listens for clipboard updates via Win32 AddClipboardFormatListener.</summary>
public sealed class ClipboardMonitor : IDisposable
{
    private readonly ClipboardHistoryStore _store;
    private HwndSource? _source;
    private bool _ignoreNext;
    private string? _lastTextFingerprint;
    private string? _lastImageFingerprint;

    private const int WM_CLIPBOARDUPDATE = 0x031D;

    public ClipboardMonitor(ClipboardHistoryStore store) => _store = store;

    public void Start()
    {
        var parameters = new HwndSourceParameters("HisCopyClipboardListener")
        {
            Width = 0,
            Height = 0,
            WindowStyle = unchecked((int)0x80000000) // WS_POPUP
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
        if (!AddClipboardFormatListener(_source.Handle))
            throw new InvalidOperationException("AddClipboardFormatListener failed");
    }

    public void IgnoreNextChange() => _ignoreNext = true;

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_CLIPBOARDUPDATE)
        {
            try { CaptureClipboard(); }
            catch { /* transient clipboard lock */ }
        }
        return IntPtr.Zero;
    }

    private void CaptureClipboard()
    {
        if (_ignoreNext)
        {
            _ignoreNext = false;
            return;
        }

        // STA — we're on the HwndSource thread which is STA
        if (System.Windows.Clipboard.ContainsImage())
        {
            var image = System.Windows.Clipboard.GetImage();
            if (image == null) return;
            var fp = $"{image.PixelWidth}x{image.PixelHeight}:{image.DpiX}:{image.DpiY}";
            if (fp == _lastImageFingerprint) return;
            _lastImageFingerprint = fp;
            _lastTextFingerprint = null;

            var path = _store.SaveImage(image);
            var thumb = new BitmapImage();
            thumb.BeginInit();
            thumb.CacheOption = BitmapCacheOption.OnLoad;
            thumb.UriSource = new Uri(path);
            thumb.DecodePixelWidth = 64;
            thumb.EndInit();
            thumb.Freeze();

            _store.AddOrBump(new ClipboardItem
            {
                Kind = ClipboardItemKind.Image,
                TextPreview = $"图片 {image.PixelWidth}×{image.PixelHeight}",
                ImagePath = path,
                ImagePreview = thumb
            });
            return;
        }

        if (System.Windows.Clipboard.ContainsFileDropList())
        {
            var files = System.Windows.Clipboard.GetFileDropList().Cast<string>().ToList();
            if (files.Count == 0) return;
            var preview = files.Count == 1
                ? Path.GetFileName(files[0])
                : $"{Path.GetFileName(files[0])} 等 {files.Count} 个文件";
            if (preview == _lastTextFingerprint) return;
            _lastTextFingerprint = preview;
            _lastImageFingerprint = null;
            _store.AddOrBump(new ClipboardItem
            {
                Kind = ClipboardItemKind.Files,
                TextPreview = preview,
                FilePaths = files
            });
            return;
        }

        if (System.Windows.Clipboard.ContainsText())
        {
            var text = System.Windows.Clipboard.GetText();
            if (string.IsNullOrWhiteSpace(text)) return;
            if (text == _lastTextFingerprint) return;
            _lastTextFingerprint = text;
            _lastImageFingerprint = null;
            var preview = text.Length <= 120 ? text : text[..117] + "…";
            preview = preview.Replace('\r', ' ').Replace('\n', ' ');
            _store.AddOrBump(new ClipboardItem
            {
                Kind = ClipboardItemKind.Text,
                TextPreview = preview,
                PlainText = text
            });
        }
    }

    public void Dispose()
    {
        if (_source != null)
        {
            RemoveClipboardFormatListener(_source.Handle);
            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
}
