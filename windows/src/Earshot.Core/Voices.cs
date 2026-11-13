namespace Earshot.Core;

/// <summary>A stretch of audio where one voice speaks. <see cref="Voice"/> is an id from the speaker separation
/// ("S0", "S1"...), the same for every turn of that voice.</summary>
public sealed record VoiceTurn(double Start, double End, string Voice);

/// <summary>What the transcript does with the voice turns: which voice said a line, and what to call each voice.</summary>
public static class Voices
{
    /// <summary>Trims overlaps so each moment belongs to one voice (the one that was already speaking).</summary>
    public static List<VoiceTurn> Exclusive(IEnumerable<VoiceTurn> turns)
    {
        var output = new List<VoiceTurn>();
        foreach (var turn in turns.OrderBy(t => t.Start))
        {
            var t = turn;
            if (output.Count > 0 && t.Start < output[^1].End) t = t with { Start = output[^1].End };
            if (t.End - t.Start >= 0.2) output.Add(t);
        }
        return output;
    }

    /// <summary>The voice heard most over [start, end], else the nearest one within a second.</summary>
    public static string? Voice(double start, double end, IReadOnlyList<VoiceTurn> turns)
    {
        var overlap = new Dictionary<string, double>();
        foreach (var t in turns.Where(t => t.End > start && t.Start < end))
            overlap[t.Voice] = overlap.GetValueOrDefault(t.Voice) + Math.Min(t.End, end) - Math.Max(t.Start, start);
        if (overlap.Count > 0)
            return overlap.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).First().Key;
        return turns.Select(t => (t.Voice, Gap: Math.Max(t.Start - end, start - t.End)))
            .Where(x => x.Gap <= 1).OrderBy(x => x.Gap).Select(x => x.Voice).FirstOrDefault();
    }

    /// <summary>A name for each voice: "Speaker 1", "Speaker 2"... in the order they first speak. With the user's
    /// microphone recorded apart (<paramref name="withUser"/>), a single voice on the other side is "Speaker 1" too,
    /// to rename like any other. No voice is ever dropped.</summary>
    public static Dictionary<string, string> Names(IReadOnlyList<VoiceTurn> turns, IReadOnlyList<NameMark> marks, bool withUser)
    {
        var order = new List<string>();
        foreach (var t in turns) if (!order.Contains(t.Voice)) order.Add(t.Voice);
        var votes = new Dictionary<string, Dictionary<string, int>>();
        foreach (var m in marks)
        {
            var t = turns.FirstOrDefault(t => m.Time >= t.Start - 0.5 && m.Time <= t.End + 0.5);
            if (t is null) continue;
            if (!votes.TryGetValue(t.Voice, out var counts)) votes[t.Voice] = counts = new();
            counts[m.Name] = counts.GetValueOrDefault(m.Name) + 1;
        }
        var names = new Dictionary<string, string>();
        foreach (var voice in order)
        {
            if (!votes.TryGetValue(voice, out var counts) || counts.Count == 0) continue;
            var total = counts.Values.Sum();
            var best = counts.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).First();
            if (best.Value >= 2 && best.Value * 2 >= total) names[voice] = best.Key;
        }
        if (order.Count <= 1 && !withUser) return names;
        var n = 1;
        foreach (var voice in order.Where(v => !names.ContainsKey(v))) names[voice] = L.Speaker(n++);
        return names;
    }

    /// <summary>Gives each line (outside the user's microphone) the name of the voice that said it.</summary>
    public static List<Segment> Label(IReadOnlyList<Segment> segments, IReadOnlyList<VoiceTurn> turns, IReadOnlyList<NameMark> marks)
    {
        if (turns.Count == 0) return segments.ToList();
        var voices = segments.Select(s => s.Mic == true ? null : Voice(s.Start, s.End, turns)).ToList();
        // Numbered in the order they first say a line, so a voice that got no line leaves no gap ("Speaker 1, 2, 4").
        var heard = new List<string>();
        foreach (var v in voices) if (v != null && !heard.Contains(v)) heard.Add(v);
        var spoken = turns.Where(t => heard.Contains(t.Voice)).OrderBy(t => heard.IndexOf(t.Voice)).ThenBy(t => t.Start).ToList();
        var names = Names(spoken, marks, withUser: segments.Any(s => s.Mic == true));
        return segments.Select((s, i) =>
        {
            if (s.Mic == true) return s;
            var voice = voices[i];
            if (voice is null || !names.TryGetValue(voice, out var name)) return s;
            var copy = s.Copy();
            copy.Speaker = name;
            return copy;
        }).ToList();
    }
}
