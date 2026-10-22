using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace HisCopy.Windows.Services;

public sealed record ReleaseInfo(string Tag, string Name, string HtmlUrl);

public static class UpdateChecker
{
    private static readonly HttpClient Http = new()
    {
        DefaultRequestHeaders =
        {
            UserAgent = { new ProductInfoHeaderValue("HisCopy-Windows", "0.1.0") },
            Accept = { new MediaTypeWithQualityHeaderValue("application/vnd.github+json") }
        }
    };

    public static async Task<ReleaseInfo?> CheckAsync(string owner, string repo, string currentVersion)
    {
        var url = $"https://api.github.com/repos/{owner}/{repo}/releases/latest";
        using var resp = await Http.GetAsync(url);
        if (!resp.IsSuccessStatusCode) return null;
        await using var stream = await resp.Content.ReadAsStreamAsync();
        using var doc = await JsonDocument.ParseAsync(stream);
        var root = doc.RootElement;
        var tag = root.GetProperty("tag_name").GetString()?.TrimStart('v') ?? "";
        if (string.IsNullOrEmpty(tag)) return null;
        if (IsSameOrOlder(tag, currentVersion)) return null;

        // Prefer a release that mentions Windows asset; still surface if newer tag exists
        var html = root.GetProperty("html_url").GetString() ?? $"https://github.com/{owner}/{repo}/releases";
        var name = root.TryGetProperty("name", out var n) ? n.GetString() ?? tag : tag;
        return new ReleaseInfo(tag, name, html);
    }

    public static void OpenInBrowser(string url) =>
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    private static bool IsSameOrOlder(string remote, string local)
    {
        try
        {
            var r = Version.Parse(Trim(remote));
            var l = Version.Parse(Trim(local));
            return r <= l;
        }
        catch
        {
            return string.Equals(remote, local, StringComparison.OrdinalIgnoreCase);
        }
    }

    private static string Trim(string v) => v.TrimStart('v', 'V').Split('-')[0];
}
