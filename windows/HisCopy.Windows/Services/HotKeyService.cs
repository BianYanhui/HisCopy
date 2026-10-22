using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace HisCopy.Windows.Services;

[Flags]
public enum Modifiers : uint
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Win = 8
}

public enum KeyCode : uint
{
    V = 0x56
}

public sealed class HotKeyService : IDisposable
{
    private const int WM_HOTKEY = 0x0312;
    private HwndSource? _source;
    private int _id = 1;
    private Action? _callback;
    private bool _registered;

    public bool Register(Modifiers modifiers, KeyCode key, Action callback)
    {
        _callback = callback;
        var parameters = new HwndSourceParameters("HisCopyHotKey")
        {
            Width = 0,
            Height = 0,
            WindowStyle = unchecked((int)0x80000000)
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
        _registered = RegisterHotKey(_source.Handle, _id, (uint)modifiers, (uint)key);
        return _registered;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == _id)
        {
            _callback?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_source != null)
        {
            if (_registered)
                UnregisterHotKey(_source.Handle, _id);
            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
