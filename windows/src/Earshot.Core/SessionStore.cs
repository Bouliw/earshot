using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Earshot.Core;

/// <summary>Session folders on disk, laid out like the Mac app's: &lt;base&gt;/&lt;title&gt;/&lt;yyyy-MM-dd&gt;/ with
/// Audio.m4a (or Audio.wav), Transcript.txt and .earshot.json.</summary>
public static class SessionStore
{
    public const string RecordName = ".earshot.json";
    public const string TranscriptName = "Transcript.txt";
    public const string AudioName = "Audio.m4a";
    public const string WaveAudioName = "Audio.wav";
    /// <summary>The PC's sound and the microphone while recording, raw so that nothing is lost if Earshot stops
    /// abruptly. Kept apart until the transcript is done, so the user's voice is never taken for someone else's.</summary>
    public const string AppTrackName = ".app.pcm";
    public const string MicTrackName = ".mic.pcm";

    static readonly CultureInfo English = CultureInfo.GetCultureInfo("en-US");
    /// <summary>The narrow no-break space Foundation puts before AM/PM: Transcript.txt reads the same as on the Mac.</summary>
    const string Nnbsp = " ";

    /// <summary>Documents\Earshot\Calls.</summary>
    public static string DefaultBase =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Earshot", "Calls");

    /// <summary>A name Windows accepts for a folder: no reserved characters, no trailing dot or space.</summary>
    public static string SafeName(string name)
    {
        var sb = new StringBuilder();
        foreach (var c in name.Trim())
            sb.Append(c < 32 || "<>:\"/\\|?*".Contains(c) ? '-' : c);
        var safe = sb.ToString().TrimEnd('.', ' ');
        if (safe.Length > 120) safe = safe[..120].TrimEnd('.', ' ');
        var reserved = new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3" };
        if (safe.Length == 0) safe = "Call";
        if (reserved.Contains(safe.ToUpperInvariant())) safe += "-";
        return safe;
    }

    /// <summary>&lt;base&gt;/&lt;group&gt;/&lt;yyyy-MM-dd&gt;, with " 2", " 3"... for further sessions the same day.</summary>
    public static string NewFolder(string baseFolder, string group, DateTime localNow)
    {
        var day = localNow.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var parent = Path.Combine(baseFolder, SafeName(group));
        var folder = Path.Combine(parent, day);
        for (var n = 2; Directory.Exists(folder); n++) folder = Path.Combine(parent, $"{day} {n}");
        return folder;
    }

    public static SessionRecord? Load(string folder)
    {
        try
        {
            var path = Path.Combine(folder, RecordName);
            if (!File.Exists(path)) return null;
            var record = JsonSerializer.Deserialize<SessionRecord>(File.ReadAllText(path, Encoding.UTF8), Json.Options);
            if (record != null) record.Folder = folder;
            return record;
        }
        catch (Exception) { return null; }
    }

    /// <summary>Every session under <paramref name="baseFolder"/>, newest first.</summary>
    public static List<SessionRecord> LoadAll(string baseFolder)
    {
        if (!Directory.Exists(baseFolder)) return new();
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(baseFolder, RecordName, SearchOption.AllDirectories).ToList(); }
        catch (Exception) { return new(); }
        return files.Select(f => Load(Path.GetDirectoryName(f)!)).OfType<SessionRecord>()
            .OrderByDescending(r => r.StartedAt).ToList();
    }

    /// <summary>Writes .earshot.json and Transcript.txt, each replaced in one move so a reader never sees half a file.</summary>
    public static void Write(SessionRecord record, string folder)
    {
        Directory.CreateDirectory(folder);
        WriteAtomically(Path.Combine(folder, RecordName), JsonSerializer.Serialize(record, Json.Options));
        WriteAtomically(Path.Combine(folder, TranscriptName), Text(record));
    }

    static void WriteAtomically(string path, string content)
    {
        var temp = path + ".tmp";
        File.WriteAllText(temp, content, new UTF8Encoding(false));
        File.Move(temp, path, overwrite: true);
    }

    /// <summary>The session's audio file, whichever format it was saved in.</summary>
    public static string? AudioFile(string folder) =>
        new[] { AudioName, WaveAudioName }.Select(n => Path.Combine(folder, n)).FirstOrDefault(File.Exists);

    static DateTime Local(DateTime utc) => DateTime.SpecifyKind(utc, DateTimeKind.Utc).ToLocalTime();

    static string WallClock(SessionRecord r, double t) =>
        Local(r.StartedAt).AddSeconds(t).ToString("h:mm:ss", English) + Nnbsp + Local(r.StartedAt).AddSeconds(t).ToString("tt", English);

    /// <summary>"November 10, 2026 at 3:05 PM", as the Mac writes it.</summary>
    public static string LongDate(DateTime utc)
    {
        var d = Local(utc);
        return d.ToString("MMMM d, yyyy", English) + " at " + d.ToString("h:mm", English) + Nnbsp + d.ToString("tt", English);
    }

    /// <summary>Transcript.txt: the title and date, then one paragraph per turn under "[h:mm:ss AM] Name".</summary>
    public static string Text(SessionRecord r)
    {
        var sb = new StringBuilder();
        sb.Append(r.Title).Append(" — ").Append(LongDate(r.StartedAt)).Append('\n');
        foreach (var t in Turn.Group(r.Segments))
        {
            sb.Append("\n[").Append(WallClock(r, t.Start)).Append(']');
            if (t.Speaker != null) sb.Append(' ').Append(t.Speaker);
            sb.Append('\n').Append(t.Text).Append('\n');
        }
        return sb.ToString();
    }
}
