namespace Earshot.Core;

/// <summary>A stretch of audio Whisper transcribes in one go. <see cref="Voice"/> is set when voices were told apart.</summary>
public sealed record Piece(double Start, double End, string? Voice = null)
{
    public double Length => End - Start;
}

/// <summary>Where to cut a recording into pieces Whisper transcribes one at a time.</summary>
public static class Chunker
{
    public const int Rate = 16_000;

    /// <summary>One piece per voice turn, joined with the next turn of the same voice when the pause is short,
    /// and cut at the quietest moment once longer than <paramref name="maxLength"/>. Short pieces give each sentence
    /// its own language; long ones give Whisper more context.</summary>
    public static List<Piece> Pieces(IEnumerable<VoiceTurn> turns, float[] samples, double maxLength)
    {
        var joined = new List<Piece>();
        foreach (var t in turns)
        {
            if (joined.Count > 0 && joined[^1].Voice == t.Voice && t.Start - joined[^1].End < 0.8 && t.End - joined[^1].Start <= maxLength)
                joined[^1] = joined[^1] with { End = t.End };
            else
                joined.Add(new Piece(t.Start, t.End, t.Voice));
        }
        return joined.SelectMany(p => Split(p, samples, maxLength)).ToList();
    }

    /// <summary>Without the voice activity model: where there is sound, found with the level of each 100 ms.</summary>
    public static List<Piece> BySoundLevel(float[] samples, double maxLength, float? level = null)
    {
        const int window = Rate / 10;
        var levels = new List<float>();
        for (var i = 0; i < samples.Length; i += window) levels.Add(Rms(samples, i, Math.Min(i + window, samples.Length)));
        // Quiet recordings (a phone memo) get a lower bar than call audio.
        var sorted = levels.OrderBy(l => l).ToList();
        var loud = sorted.Count == 0 ? 0 : sorted[Math.Min(sorted.Count - 1, sorted.Count * 9 / 10)];
        var threshold = level ?? Math.Max(0.002f, Math.Min(0.004f, loud / 10));
        var regions = new List<Piece>();
        for (var i = 0; i < levels.Count; i++)
        {
            if (levels[i] <= threshold) continue;
            var t = i / 10.0;
            if (regions.Count > 0 && t - regions[^1].End < 0.8) regions[^1] = regions[^1] with { End = t + 0.1 };
            else regions.Add(new Piece(t, t + 0.1));
        }
        var duration = (double)samples.Length / Rate;
        return regions
            .Select(r => new Piece(Math.Max(0, r.Start - 0.2), Math.Min(duration, r.End + 0.2)))
            .Where(r => r.Length >= 0.4)
            .SelectMany(r => Split(r, samples, maxLength)).ToList();
    }

    /// <summary>Stretches found by the voice activity model, padded a little so the first and last syllables stay,
    /// joined where the padding makes them touch, then cut to <paramref name="maxLength"/>.</summary>
    public static List<Piece> FromSpeech(IEnumerable<(double Start, double End)> speech, float[] samples, double maxLength, double padding = 0.2)
    {
        var duration = (double)samples.Length / Rate;
        var merged = new List<Piece>();
        foreach (var (start, end) in speech.Where(s => s.End > s.Start).OrderBy(s => s.Start))
        {
            var p = new Piece(Math.Max(0, start - padding), Math.Min(duration, end + padding));
            if (merged.Count > 0 && p.Start <= merged[^1].End && p.End - merged[^1].Start <= maxLength)
                merged[^1] = merged[^1] with { End = Math.Max(merged[^1].End, p.End) };
            else if (merged.Count > 0 && p.Start < merged[^1].End)
                merged.Add(p with { Start = merged[^1].End });
            else
                merged.Add(p);
        }
        return merged.Where(p => p.Length > 0.05).SelectMany(p => Split(p, samples, maxLength)).ToList();
    }

    /// <summary>Cuts a long piece in the quietest 100 ms of the last 5 s before each <paramref name="maxLength"/>.</summary>
    public static List<Piece> Split(Piece piece, float[] samples, double maxLength)
    {
        var output = new List<Piece>();
        var start = piece.Start;
        while (piece.End - start > maxLength)
        {
            double best = start + maxLength;
            var bestLevel = float.MaxValue;
            for (var t = start + maxLength - 5; t + 0.1 <= start + maxLength + 1e-9; t += 0.1)
            {
                int a = (int)(t * Rate), b = Math.Min(samples.Length, (int)((t + 0.1) * Rate));
                if (a < 0 || a >= b) continue;
                var l = Rms(samples, a, b);
                if (l < bestLevel) { bestLevel = l; best = t + 0.05; }
            }
            output.Add(new Piece(start, best, piece.Voice));
            start = best;
        }
        output.Add(new Piece(start, piece.End, piece.Voice));
        return output;
    }

    public static float Rms(float[] s, int from, int to)
    {
        from = Math.Max(0, from); to = Math.Min(s.Length, to);
        if (to <= from) return 0;
        double sum = 0;
        for (var i = from; i < to; i++) sum += s[i] * s[i];
        return (float)Math.Sqrt(sum / (to - from));
    }

    /// <summary>The samples of a piece; padded with silence to just over a second, since whisper.cpp skips anything shorter.</summary>
    public static float[] Clip(float[] samples, Piece piece)
    {
        int a = Math.Max(0, (int)(piece.Start * Rate)), b = Math.Min(samples.Length, (int)(piece.End * Rate));
        if (a >= b) return Array.Empty<float>();
        var clip = new float[Math.Max(b - a, 17_600)];
        Array.Copy(samples, a, clip, 0, b - a);
        return clip;
    }
}
