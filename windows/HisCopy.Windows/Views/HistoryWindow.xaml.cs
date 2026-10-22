using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using HisCopy.Windows.Models;
using HisCopy.Windows.Services;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace HisCopy.Windows.Views;

public partial class HistoryWindow : Window
{
    private readonly ClipboardHistoryStore _store;
    private bool _searchFocused;
    private bool _suppressDeactivate;

    public event EventHandler<PasteRequest>? PasteRequested;

    public HistoryWindow(ClipboardHistoryStore store)
    {
        InitializeComponent();
        _store = store;
        List.ItemsSource = _store.Items;
        ((INotifyCollectionChanged)_store.Items).CollectionChanged += (_, _) =>
        {
            if (List.SelectedIndex < 0 && List.Items.Count > 0)
                List.SelectedIndex = 0;
        };
        SearchBox.GotKeyboardFocus += (_, _) => _searchFocused = true;
        SearchBox.LostKeyboardFocus += (_, _) => _searchFocused = false;
    }

    public void ShowCentered()
    {
        RefreshFilter();
        if (List.Items.Count > 0) List.SelectedIndex = 0;
        var work = SystemParameters.WorkArea;
        Left = work.Left + (work.Width - Width) / 2;
        Top = work.Top + (work.Height - Height) / 2;
        _suppressDeactivate = true;
        Show();
        Activate();
        List.Focus();
        _suppressDeactivate = false;
    }

    public void HidePanel()
    {
        SearchBox.Text = "";
        Hide();
    }

    private void RefreshFilter()
    {
        var q = SearchBox.Text?.Trim() ?? "";
        var view = System.Windows.Data.CollectionViewSource.GetDefaultView(_store.Items);
        if (string.IsNullOrEmpty(q))
            view.Filter = null;
        else
            view.Filter = o => o is ClipboardItem it &&
                               (it.TextPreview?.Contains(q, StringComparison.OrdinalIgnoreCase) == true
                                || it.PlainText?.Contains(q, StringComparison.OrdinalIgnoreCase) == true);
        view.Refresh();
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        RefreshFilter();
        if (List.Items.Count > 0) List.SelectedIndex = 0;
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            HidePanel();
            e.Handled = true;
            return;
        }

        if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control)
        {
            SearchBox.Focus();
            SearchBox.SelectAll();
            e.Handled = true;
            return;
        }

        if (_searchFocused) return;

        if (e.Key == Key.Enter)
        {
            RequestPaste(plainTextOnly: Keyboard.Modifiers.HasFlag(ModifierKeys.Control));
            e.Handled = true;
        }
        else if (e.Key == Key.Down)
        {
            if (List.SelectedIndex < List.Items.Count - 1) List.SelectedIndex++;
            e.Handled = true;
        }
        else if (e.Key == Key.Up)
        {
            if (List.SelectedIndex > 0) List.SelectedIndex--;
            e.Handled = true;
        }
    }

    private void OnListKeyDown(object sender, KeyEventArgs e) => OnKeyDown(sender, e);

    private void OnListDoubleClick(object sender, MouseButtonEventArgs e) =>
        RequestPaste(plainTextOnly: false);

    private void RequestPaste(bool plainTextOnly)
    {
        if (List.SelectedItem is not ClipboardItem item) return;
        PasteRequested?.Invoke(this, new PasteRequest { Item = item, PlainTextOnly = plainTextOnly });
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        if (_suppressDeactivate) return;
        HidePanel();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        HidePanel();
    }
}
