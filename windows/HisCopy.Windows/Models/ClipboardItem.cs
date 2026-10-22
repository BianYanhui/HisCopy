using System.Text.Json.Serialization;
using System.Windows.Media.Imaging;

namespace HisCopy.Windows.Models;

public enum ClipboardItemKind
{
    Text,
    Image,
    Files
}

public sealed class ClipboardItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public ClipboardItemKind Kind { get; set; }
    public string TextPreview { get; set; } = "";
    public string? PlainText { get; set; }
    public string? ImagePath { get; set; }
    public List<string>? FilePaths { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public bool IsFavorite { get; set; }

    [JsonIgnore]
    public BitmapSource? ImagePreview { get; set; }

    public string KindLabel => Kind switch
    {
        ClipboardItemKind.Image => "图片",
        ClipboardItemKind.Files => "文件",
        _ => "文本"
    };
}

public sealed class PasteRequest
{
    public required ClipboardItem Item { get; init; }
    public bool PlainTextOnly { get; init; }
}
