using System.Text.Json;

namespace Earshot.Core;

/// <summary>Once a day, Earshot asks GitHub for the number of its latest release. Nothing else is sent: no audio, no
/// transcript, no identifier. Off when "Check for new versions" is unticked in Settings.</summary>
public static class Updates
{
    public const string ReleasesPage = "https://github.com/Bouliw/earshot/releases/latest";
    const string LatestRelease = "https://api.github.com/repos/Bouliw/earshot/releases/latest";

    static readonly HttpClient Http = CreateClient();

    static HttpClient CreateClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        // GitHub's API turns away requests without a User-Agent.
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Earshot-Windows");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return http;
    }

    /// <summary>The version of this copy, "0.6.3".</summary>
    public static string Current => typeof(Updates).Assembly.GetName().Version?.ToString(3) ?? "0";

    /// <summary>The newer version on GitHub, or null: this copy is the latest, or nothing could be checked (offline,
    /// rate limited, an unexpected answer), and it is tried again the next day.</summary>
    public static async Task<string?> NewerVersionAsync(CancellationToken cancel = default)
    {
        try
        {
            var latest = VersionFromRelease(await Http.GetStringAsync(LatestRelease, cancel));
            return latest != null && IsNewer(latest, Current) ? latest : null;
        }
        catch (Exception) { return null; }
    }

    /// <summary>The version in a GitHub release's JSON: its tag without the leading "v".</summary>
    public static string? VersionFromRelease(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object
                || !doc.RootElement.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String) return null;
            var text = tag.GetString()!;
            var version = text.StartsWith('v') ? text[1..] : text;
            return version.Length > 0 && char.IsDigit(version[0]) ? version : null;
        }
        catch (JsonException) { return null; }
    }

    /// <summary>Compares dotted versions number by number: 0.6.10 is newer than 0.6.9, and 0.7 the same as 0.7.0.</summary>
    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string v) => v.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var a = Parts(candidate);
        var b = Parts(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
