namespace Earshot.Core;

/// <summary>Silero's voice activity model: where someone is actually speaking.</summary>
public interface IVoiceActivity
{
    /// <summary>Stretches of speech in 16 kHz mono samples, in seconds, sorted, none longer than <paramref name="maxLength"/>.</summary>
    IReadOnlyList<(double Start, double End)> Speech(float[] samples, double maxLength);
}

/// <summary>Tells voices apart in a recording.</summary>
public interface IVoiceSeparator
{
    IReadOnlyList<VoiceTurn> Turns(float[] samples, Action<double> progress);
}

/// <summary>Whisper.</summary>
public interface ISpeechRecognizer
{
    /// <summary>The language spoken in <paramref name="samples"/> and how sure Whisper is (0...1).</summary>
    (string Code, float Probability)? DetectLanguage(float[] samples);
    IReadOnlyList<RecognizedLine> Transcribe(float[] samples, string language);
}

/// <summary>Transcribes a whole recording once it is over: voices first, then each piece in its own language.
/// Only the stretches where the voice activity model hears someone go to Whisper, on both tracks.</summary>
public sealed class BatchTranscriber
{
    public sealed class Input
    {
        /// <summary>The PC's sound (the other side of the call).</summary>
        public float[] Samples { get; init; } = Array.Empty<float>();
        /// <summary>The user's microphone, kept apart so it is never mistaken for another voice.</summary>
        public float[]? Mic { get; init; }
        public IReadOnlyList<NameMark> Marks { get; init; } = Array.Empty<NameMark>();
        /// <summary>"auto", "en", "fr"...</summary>
        public string Language { get; init; } = "auto";
        public bool SeparateVoices { get; init; } = true;
        public string UserName { get; init; } = L.Me;
        /// <summary>Awaited before each piece: holds the work while a recording runs.</summary>
        public Func<Task> Pause { get; init; } = () => Task.CompletedTask;
    }

    readonly ISpeechRecognizer whisper;
    readonly IVoiceActivity? vad;
    readonly IVoiceSeparator? separator;

    public BatchTranscriber(ISpeechRecognizer whisper, IVoiceActivity? vad, IVoiceSeparator? separator)
    {
        this.whisper = whisper;
        this.vad = vad;
        this.separator = separator;
    }

    /// <summary>Where a voice is heard. Falls back on the sound level when the model is missing or fails.</summary>
    public List<Piece> Voiced(float[] samples, double maxLength, float? level = null)
    {
        if (samples.Length == 0) return new();
        if (vad != null)
        {
            try { return Chunker.FromSpeech(vad.Speech(samples, maxLength), samples, maxLength); }
            catch (Exception) { /* the sound level below */ }
        }
        return Chunker.BySoundLevel(samples, maxLength, level);
    }

    /// <summary>Progress goes 0...1: voices take the first tenth, transcription the rest.</summary>
    public async Task<List<Segment>> RunAsync(Input input, Action<double> progress, CancellationToken cancel = default)
    {
        await input.Pause();
        IReadOnlyList<VoiceTurn> turns = Array.Empty<VoiceTurn>();
        if (input.SeparateVoices && separator != null && input.Samples.Length > 0)
        {
            // A failure here (no network for the first download, say) still leaves a transcript, without voices.
            try { turns = Voices.Exclusive(separator.Turns(input.Samples, p => progress(p * 0.1))); }
            catch (Exception) { turns = Array.Empty<VoiceTurn>(); }
        }
        progress(0.1);
        var maxLength = input.Language == "auto" ? 15.0 : 25.0;
        var pieces = turns.Count == 0 ? Voiced(input.Samples, maxLength) : Chunker.Pieces(turns, input.Samples, maxLength);
        // The microphone is never muted: the PC's sound is taken out of it, so the user's words stay even when they
        // speak over the other side.
        float[]? mic = input.Mic is { Length: > 0 } m ? EchoCanceller.Clean(m, input.Samples) : null;
        // While the other side talks, what is only the call coming back through the microphone stays out of Whisper.
        var micPieces = mic != null ? EchoLeak.Keeping(Voiced(mic, maxLength, 0.004f), mic, input.Samples) : new List<Piece>();
        var total = Math.Max(1, pieces.Concat(micPieces).Sum(p => p.Length));
        var done = 0.0;

        var segments = new List<Segment>();
        var lastLanguage = new Dictionary<string, string>();
        var tracks = new[] { (pieces, input.Samples, false), (micPieces, mic ?? Array.Empty<float>(), true) };
        foreach (var (list, samples, isMic) in tracks)
        {
            foreach (var piece in list)
            {
                cancel.ThrowIfCancellationRequested();
                await input.Pause();
                var clip = Chunker.Clip(samples, piece);
                if (clip.Length == 0) continue;
                var language = input.Language;
                if (language == "auto")
                {
                    // A short piece says too little to tell: keep the language this voice spoke last.
                    var key = isMic ? "mic" : piece.Voice ?? "";
                    var detected = piece.Length >= 2.5 ? whisper.DetectLanguage(clip) : null;
                    if (detected is { } d && (d.Probability >= 0.5 || !lastLanguage.ContainsKey(key))) language = d.Code;
                    else language = lastLanguage.GetValueOrDefault(key) ?? detected?.Code ?? "auto";
                    lastLanguage[key] = language;
                }
                foreach (var line in whisper.Transcribe(clip, language))
                {
                    if (!TranscriptRules.Keep(line, clip)) continue;
                    segments.Add(new Segment(piece.Start + line.Start, Math.Min(piece.End, piece.Start + line.End),
                        line.Text.Trim(), isMic ? input.UserName : null, isMic ? true : null));
                }
                done += piece.Length;
                progress(0.1 + 0.9 * done / total);
            }
        }
        segments = EchoLines.Dropping(segments.OrderBy(s => s.Start).ToList());
        if (turns.Count > 0) segments = Voices.Label(segments, turns, input.Marks);
        // Voices not told apart (turned off, or the models could not load): the other side is one speaker.
        foreach (var s in segments.Where(s => s.Mic != true && s.Speaker == null)) s.Speaker = L.Speaker(1);
        progress(1);
        return TranscriptRules.DroppingLoops(segments);
    }
}
