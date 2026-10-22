using System.Runtime.InteropServices;
using System.Windows;
using HisCopy.Windows.Models;

namespace HisCopy.Windows.Services;

public static class PasteService
{
    public static void Paste(ClipboardItem item, bool plainTextOnly)
    {
        try
        {
            if (item.Kind == ClipboardItemKind.Image && !string.IsNullOrEmpty(item.ImagePath) && !plainTextOnly)
            {
                var bi = new System.Windows.Media.Imaging.BitmapImage(new Uri(item.ImagePath));
                System.Windows.Clipboard.SetImage(bi);
            }
            else if (item.Kind == ClipboardItemKind.Files && item.FilePaths is { Count: > 0 } && !plainTextOnly)
            {
                var col = new System.Collections.Specialized.StringCollection();
                col.AddRange(item.FilePaths.ToArray());
                System.Windows.Clipboard.SetFileDropList(col);
            }
            else
            {
                var text = item.PlainText ?? item.TextPreview;
                System.Windows.Clipboard.SetText(text ?? "");
            }

            // Simulate Ctrl+V to the foreground window
            SendCtrlV();
        }
        catch
        {
            // Clipboard busy — user can paste manually
        }
    }

    private static void SendCtrlV()
    {
        const byte VK_CONTROL = 0x11;
        const byte VK_V = 0x56;
        const uint KEYEVENTF_KEYUP = 0x0002;

        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
