using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;
using System.Windows.Media.Imaging;
using HisCopy.Windows.Models;

namespace HisCopy.Windows.Services;

public sealed class ClipboardHistoryStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly string _root;
    private readonly string _indexPath;
    private readonly string _imagesDir;
    private readonly object _gate = new();

    public ObservableCollection<ClipboardItem> Items { get; } = new();

    public int MaxItems { get; set; } = 200;
    public TimeSpan MaxAge { get; set; } = TimeSpan.FromDays(30);

    public ClipboardHistoryStore()
    {
        _root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HisCopy");
        _indexPath = Path.Combine(_root, "history.json");
        _imagesDir = Path.Combine(_root, "images");
        Directory.CreateDirectory(_imagesDir);
    }

    public void Load()
    {
        lock (_gate)
        {
            Items.Clear();
            if (!File.Exists(_indexPath)) return;
            try
            {
                var json = File.ReadAllText(_indexPath);
                var list = JsonSerializer.Deserialize<List<ClipboardItem>>(json, JsonOptions) ?? new();
                foreach (var item in list.OrderByDescending(i => i.CreatedAt))
                {
                    if (item.Kind == ClipboardItemKind.Image && !string.IsNullOrEmpty(item.ImagePath) && File.Exists(item.ImagePath))
                    {
                        try
                        {
                            var bi = new BitmapImage();
                            bi.BeginInit();
                            bi.CacheOption = BitmapCacheOption.OnLoad;
                            bi.UriSource = new Uri(item.ImagePath);
                            bi.DecodePixelWidth = 64;
                            bi.EndInit();
                            bi.Freeze();
                            item.ImagePreview = bi;
                        }
                        catch { /* ignore corrupt */ }
                    }
                    Items.Add(item);
                }
                TrimUnlocked();
            }
            catch
            {
                // corrupt index — start fresh
            }
        }
    }

    public void Save()
    {
        lock (_gate)
        {
            Directory.CreateDirectory(_root);
            var snapshot = Items.ToList();
            File.WriteAllText(_indexPath, JsonSerializer.Serialize(snapshot, JsonOptions));
        }
    }

    public void AddOrBump(ClipboardItem item)
    {
        lock (_gate)
        {
            // Dedup: move identical text/image to top
            ClipboardItem? existing = null;
            if (item.Kind == ClipboardItemKind.Text && !string.IsNullOrEmpty(item.PlainText))
            {
                existing = Items.FirstOrDefault(i =>
                    i.Kind == ClipboardItemKind.Text && i.PlainText == item.PlainText);
            }
            else if (item.Kind == ClipboardItemKind.Image && !string.IsNullOrEmpty(item.TextPreview))
            {
                existing = Items.FirstOrDefault(i =>
                    i.Kind == ClipboardItemKind.Image && i.TextPreview == item.TextPreview);
            }

            if (existing != null)
            {
                Items.Remove(existing);
                existing.CreatedAt = DateTimeOffset.Now;
                Items.Insert(0, existing);
            }
            else
            {
                Items.Insert(0, item);
            }
            TrimUnlocked();
            SaveUnlocked();
        }
    }

    public void ToggleFavorite(ClipboardItem item)
    {
        lock (_gate)
        {
            item.IsFavorite = !item.IsFavorite;
            SaveUnlocked();
        }
    }

    public void Remove(ClipboardItem item)
    {
        lock (_gate)
        {
            Items.Remove(item);
            if (item.Kind == ClipboardItemKind.Image && !string.IsNullOrEmpty(item.ImagePath))
            {
                try { File.Delete(item.ImagePath); } catch { }
            }
            SaveUnlocked();
        }
    }

    public string SaveImage(BitmapSource source)
    {
        Directory.CreateDirectory(_imagesDir);
        var path = Path.Combine(_imagesDir, $"{Guid.NewGuid():N}.png");
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var fs = File.Create(path);
        encoder.Save(fs);
        return path;
    }

    private void TrimUnlocked()
    {
        var cutoff = DateTimeOffset.Now - MaxAge;
        var doomed = Items.Where(i => !i.IsFavorite && i.CreatedAt < cutoff).ToList();
        foreach (var d in doomed) Items.Remove(d);

        while (Items.Count > MaxItems)
        {
            var last = Items.LastOrDefault(i => !i.IsFavorite);
            if (last == null) break;
            Items.Remove(last);
        }
    }

    private void SaveUnlocked()
    {
        Directory.CreateDirectory(_root);
        File.WriteAllText(_indexPath, JsonSerializer.Serialize(Items.ToList(), JsonOptions));
    }
}
