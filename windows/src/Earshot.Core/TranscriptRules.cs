namespace Earshot.Core;

/// <summary>What Whisper wrote for one stretch of a clip (times relative to the clip).</summary>
public sealed record RecognizedLine(double Start, double End, string Text, float NoSpeechProbability);

/// <summary>Which lines Whisper wrote are kept. There is no list of banned phrases: a line goes only when Whisper itself
/// rates it as probably not speech, when the audio under it is near silent, when it is a sound annotation such as
/// "[Music]", or when the same short line loops five times or more in a row.</summary>
public static class TranscriptRules
{
    public const float NoSpeechLimit = 0.6f;
    public const float SilenceLevel = 0.001f;

    /// <summary>"[Music]", "(laughs)", "*sigh*": Whisper describing a sound, not words.</summary>
    public static bool IsAnnotation(string text)
    {
        var t = text.Trim();
        return t.Length == 0 || t.StartsWith('[') || t.StartsWith('(') || t.StartsWith('*')
            || t.All(c => char.IsPunctuation(c) || char.IsWhiteSpace(c));
    }

    public static bool Keep(RecognizedLine line, float[] clip)
    {
        if (IsAnnotation(line.Text) || line.NoSpeechProbability >= NoSpeechLimit) return false;
        int a = (int)(line.Start * Chunker.Rate), b = Math.Min(clip.Length, (int)(line.End * Chunker.Rate));
        return a < b && Chunker.Rms(clip, a, b) > SilenceLevel;
    }

    static readonly char[] Punctuation = ".,;:!?…-–—\"'«»“”‘’()[] ".ToCharArray();
    static string Key(Segment s) => s.Text.Trim().Trim(Punctuation).ToLowerInvariant();

    /// <summary>Whisper looping on silence: the same short line five times or more in a row from the same speaker.
    /// A real conversation does not do that, so the whole run goes.</summary>
    public static List<Segment> DroppingLoops(IReadOnlyList<Segment> segments)
    {
        var output = new List<Segment>();
        var i = 0;
        while (i < segments.Count)
        {
            var j = i + 1;
            while (j < segments.Count && Key(segments[j]) == Key(segments[i])
                   && segments[j].Speaker == segments[i].Speaker && segments[j].Mic == segments[i].Mic) j++;
            var shortLine = Key(segments[i]).Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 4;
            if (!(shortLine && j - i >= 5)) output.AddRange(segments.Skip(i).Take(j - i));
            i = j;
        }
        return output;
    }
}

/// <summary>Keeps the far side's voice out of the microphone track: while the PC plays someone talking, laptop speakers
/// feed it back into the microphone, and it would be transcribed twice. The microphone is muted over those moments
/// (plus a short tail for the room's echo), as the Mac app does.</summary>
public static class MicGate
{
    public static float[] Apply(float[] app, float[] mic, float level = 0.01f, double tail = 0.25)
    {
        const int window = Chunker.Rate / 20;  // 50 ms
        var output = (float[])mic.Clone();
        var hold = (int)(tail * Chunker.Rate);
        var mutedUntil = -1;
        for (var i = 0; i < mic.Length; i += window)
        {
            var end = Math.Min(i + window, mic.Length);
            if (i < app.Length && Chunker.Rms(app, i, Math.Min(end, app.Length)) > level) mutedUntil = end + hold;
            if (i < mutedUntil) Array.Clear(output, i, Math.Min(end, mutedUntil) - i);
        }
        return output;
    }
}
