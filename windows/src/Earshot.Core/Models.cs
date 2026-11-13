using System.Text.Json.Serialization;

namespace Earshot.Core;

/// <summary>One timestamped piece of transcript. Times are seconds from the start of the session.</summary>
/// <remarks>Properties are declared in alphabetical order: the JSON matches the Mac app's sorted keys.</remarks>
public sealed class Segment
{
    [JsonPropertyName("end")] public double End { get; set; }
    [JsonPropertyName("id")] public string Id { get; set; } = Ids.New();
    /// <summary>Said into the user's microphone (the speaker is then always the user).</summary>
    [JsonPropertyName("mic"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public bool? Mic { get; set; }
    [JsonPropertyName("speaker"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Speaker { get; set; }
    [JsonPropertyName("start")] public double Start { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";

    public Segment() { }

    public Segment(double start, double end, string text, string? speaker = null, bool? mic = null)
    {
        Start = start; End = end; Text = text; Speaker = speaker; Mic = mic;
    }

    public Segment Copy() => (Segment)MemberwiseClone();
}

/// <summary>A speaker name seen at a moment of the session (seconds from its start).</summary>
public sealed class NameMark
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("time")] public double Time { get; set; }
}

/// <summary>Everything saved about a session, stored as <c>.earshot.json</c> in the session folder.</summary>
public sealed class SessionRecord
{
    public const string Pending = "pending";
    public const string Failed = "failed";

    [JsonPropertyName("appName")] public string AppName { get; set; } = "Windows";
    [JsonPropertyName("bundleID")] public string BundleId { get; set; } = "windows.system-audio";
    [JsonPropertyName("duration")] public double Duration { get; set; }
    /// <summary>Why the transcription failed, when <see cref="Status"/> is "failed".</summary>
    [JsonPropertyName("failure"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Failure { get; set; }
    [JsonPropertyName("id")] public string Id { get; set; } = Ids.New();
    [JsonPropertyName("names"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public List<NameMark>? Names { get; set; }
    [JsonPropertyName("segments")] public List<Segment> Segments { get; set; } = new();
    [JsonPropertyName("source"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Source { get; set; }
    [JsonPropertyName("startedAt"), JsonConverter(typeof(Iso8601Converter))] public DateTime StartedAt { get; set; } = DateTime.UtcNow;
    /// <summary>"pending" while the audio waits to be transcribed, "failed" when it could not be; null once done.</summary>
    [JsonPropertyName("status"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Status { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = "";

    /// <summary>Not stored: where the record was loaded from.</summary>
    [JsonIgnore] public string? Folder { get; set; }

    /// <summary>Name of the library group (the folder the session was filed under).</summary>
    [JsonIgnore] public string Group => Folder is null ? Title : Path.GetFileName(Path.GetDirectoryName(Folder.TrimEnd(Path.DirectorySeparatorChar))) ?? Title;

    /// <summary>Distinct speaker names, in the order they first speak.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> Speakers
    {
        get
        {
            var seen = new HashSet<string>();
            return Segments.Where(s => s.Speaker != null).Select(s => s.Speaker!).Where(seen.Add).ToList();
        }
    }

    /// <summary>Every line from <paramref name="old"/> (null: the lines without a name) now says <paramref name="name"/>.
    /// Giving two speakers the same name merges them.</summary>
    public void Rename(string? old, string name)
    {
        name = name.Trim();
        if (name.Length == 0) return;
        foreach (var s in Segments.Where(s => s.Speaker == old)) s.Speaker = name;
    }
}

/// <summary>Consecutive segments from the same speaker, as shown on screen and written to Transcript.txt.</summary>
public sealed record Turn(string Id, string? Speaker, double Start, string Text)
{
    public static List<Turn> Group(IEnumerable<Segment> segments)
    {
        var turns = new List<Turn>();
        foreach (var s in segments)
        {
            if (turns.Count > 0 && turns[^1].Speaker == s.Speaker && s.Start - turns[^1].Start < 120)
                turns[^1] = turns[^1] with { Text = turns[^1].Text + " " + s.Text };
            else
                turns.Add(new Turn(s.Id, s.Speaker, s.Start, s.Text));
        }
        return turns;
    }
}

public static class Ids
{
    /// <summary>Upper-case UUIDs, like the ones Foundation writes on the Mac.</summary>
    public static string New() => Guid.NewGuid().ToString().ToUpperInvariant();
}

public static class Clock
{
    /// <summary>75 -> "1:15", 3725 -> "1:02:05"</summary>
    public static string Format(double seconds)
    {
        var s = (int)Math.Floor(Math.Max(0, seconds));
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }
}
