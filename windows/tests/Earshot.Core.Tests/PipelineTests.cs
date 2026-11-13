using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

public sealed class PipelineTests
{
    public PipelineTests() => L.Use("en");

    const int Rate = Chunker.Rate;

    static float[] Tone(double seconds, float amplitude = 0.1f, double hz = 220) =>
        Enumerable.Range(0, (int)(seconds * Rate)).Select(i => (float)(amplitude * Math.Sin(2 * Math.PI * hz * i / Rate))).ToArray();

    static float[] Join(params float[][] parts) => parts.SelectMany(p => p).ToArray();
    static float[] Silence(double seconds) => new float[(int)(seconds * Rate)];

    /// <summary>Whisper stand-in: one line per clip, with the text and no-speech rating given.</summary>
    sealed class FakeWhisper : ISpeechRecognizer
    {
        public Func<float[], string> Text = _ => "Hello.";
        public float NoSpeech;
        public string Detected = "fr";
        public float Confidence = 0.9f;
        public readonly List<string> Languages = new();

        public (string Code, float Probability)? DetectLanguage(float[] samples) => (Detected, Confidence);

        public IReadOnlyList<RecognizedLine> Transcribe(float[] samples, string language)
        {
            Languages.Add(language);
            var length = samples.Length / (double)Rate;
            return new[] { new RecognizedLine(0, length, " " + Text(samples), NoSpeech) };
        }
    }

    sealed class FakeVad : IVoiceActivity
    {
        public IReadOnlyList<(double Start, double End)> Speech(float[] samples, double maxLength) =>
            Chunker.BySoundLevel(samples, maxLength, 0.01f).Select(p => (p.Start + 0.2, p.End - 0.2)).ToList();
    }

    sealed class FakeSeparator : IVoiceSeparator
    {
        public IReadOnlyList<VoiceTurn> Result = Array.Empty<VoiceTurn>();
        public bool Throws;
        public IReadOnlyList<VoiceTurn> Turns(float[] samples, Action<double> progress) =>
            Throws ? throw new IOException("no network") : Result;
    }

    [Fact]
    public async Task MicrophoneLinesCarryTheUsersNameAndTheOtherSideIsSpeakerOne()
    {
        var app = Join(Tone(2), Silence(6));
        var mic = Join(Silence(4), Tone(2), Silence(2));
        var batch = new BatchTranscriber(new FakeWhisper(), new FakeVad(), null);
        var lines = await batch.RunAsync(new BatchTranscriber.Input { Samples = app, Mic = mic, UserName = "Ada" }, _ => { });
        Assert.Equal(2, lines.Count);
        Assert.Equal(("Speaker 1", (bool?)null), (lines[0].Speaker, lines[0].Mic));
        Assert.Equal(("Ada", (bool?)true), (lines[1].Speaker, lines[1].Mic));
        Assert.True(lines[0].Start < lines[1].Start);
        Assert.Equal("Hello.", lines[0].Text);
    }

    [Fact]
    public async Task NoiseOnTheMicrophoneNeverReachesWhisper()
    {
        var random = new Random(1);
        var noise = Enumerable.Range(0, 10 * Rate).Select(_ => (float)(random.NextDouble() - 0.5) * 0.004f).ToArray();
        var whisper = new FakeWhisper();
        var batch = new BatchTranscriber(whisper, new FakeVad(), null);
        var lines = await batch.RunAsync(new BatchTranscriber.Input { Samples = Silence(10), Mic = noise }, _ => { });
        Assert.Empty(lines);
        Assert.Empty(whisper.Languages);
    }

    [Fact]
    public async Task StockPhrasesAreKeptWhenWhisperHearsSpeech()
    {
        // No list of banned phrases: "Thank you." said for real stays.
        var batch = new BatchTranscriber(new FakeWhisper { Text = _ => "Thank you." }, new FakeVad(), null);
        var lines = await batch.RunAsync(new BatchTranscriber.Input { Samples = Tone(2) }, _ => { });
        Assert.Equal("Thank you.", Assert.Single(lines).Text);
    }

    [Fact]
    public async Task LinesWhisperRatesAsNotSpeechAreDropped()
    {
        var batch = new BatchTranscriber(new FakeWhisper { NoSpeech = 0.8f }, new FakeVad(), null);
        Assert.Empty(await batch.RunAsync(new BatchTranscriber.Input { Samples = Tone(3) }, _ => { }));
    }

    [Fact]
    public async Task EachVoiceGetsItsNameAndNoneIsDropped()
    {
        var app = Join(Tone(3), Silence(1), Tone(3), Silence(1), Tone(0.6));
        var separator = new FakeSeparator
        {
            Result = new[] { new VoiceTurn(0, 3, "S1"), new VoiceTurn(4, 7, "S0"), new VoiceTurn(8, 8.6, "S2") },
        };
        var batch = new BatchTranscriber(new FakeWhisper(), new FakeVad(), separator);
        var lines = await batch.RunAsync(new BatchTranscriber.Input { Samples = app }, _ => { });
        Assert.Equal(new[] { "Speaker 1", "Speaker 2", "Speaker 3" }, lines.Select(l => l.Speaker));
    }

    [Fact]
    public async Task ASeparationFailureStillLeavesATranscript()
    {
        var batch = new BatchTranscriber(new FakeWhisper(), new FakeVad(), new FakeSeparator { Throws = true });
        var lines = await batch.RunAsync(new BatchTranscriber.Input { Samples = Tone(2) }, _ => { });
        Assert.Equal("Speaker 1", Assert.Single(lines).Speaker);
    }

    [Fact]
    public async Task WithoutTheVoiceModelTheSoundLevelIsUsed()
    {
        var batch = new BatchTranscriber(new FakeWhisper(), null, null);
        var lines = await batch.RunAsync(new BatchTranscriber.Input { Samples = Join(Silence(2), Tone(2)) }, _ => { });
        Assert.InRange(Assert.Single(lines).Start, 1.5, 2.1);
    }

    [Fact]
    public async Task ShortPiecesKeepTheLanguageTheVoiceSpokeLast()
    {
        var whisper = new FakeWhisper { Detected = "fr" };
        var batch = new BatchTranscriber(whisper, new FakeVad(), null);
        await batch.RunAsync(new BatchTranscriber.Input { Samples = Join(Tone(4), Silence(2), Tone(1.2)) }, _ => { });
        Assert.Equal(new[] { "fr", "fr" }, whisper.Languages);

        whisper = new FakeWhisper { Detected = "en", Confidence = 0.3f };
        batch = new BatchTranscriber(whisper, new FakeVad(), null);
        await batch.RunAsync(new BatchTranscriber.Input { Samples = Tone(4), Language = "fr" }, _ => { });
        Assert.Equal(new[] { "fr" }, whisper.Languages);
    }

    [Fact]
    public async Task ProgressEndsAtOne()
    {
        var steps = new List<double>();
        var batch = new BatchTranscriber(new FakeWhisper(), new FakeVad(), null);
        await batch.RunAsync(new BatchTranscriber.Input { Samples = Join(Tone(2), Silence(1), Tone(2)) }, steps.Add);
        Assert.Equal(1, steps[^1]);
        Assert.True(steps.Zip(steps.Skip(1)).All(p => p.Second >= p.First));
    }

    [Fact]
    public void LoopsOfFiveShortLinesGo()
    {
        Segment S(string text, string speaker = "A") => new(0, 1, text, speaker);
        var five = Enumerable.Range(0, 5).Select(_ => S("Merci.")).ToList();
        Assert.Empty(TranscriptRules.DroppingLoops(five));
        var four = Enumerable.Range(0, 4).Select(_ => S("Merci.")).ToList();
        Assert.Equal(4, TranscriptRules.DroppingLoops(four).Count);
        var longLines = Enumerable.Range(0, 6).Select(_ => S("this sentence has more than four words")).ToList();
        Assert.Equal(6, TranscriptRules.DroppingLoops(longLines).Count);
        var twoSpeakers = new[] { S("ok"), S("ok", "B"), S("ok"), S("ok", "B"), S("ok") };
        Assert.Equal(5, TranscriptRules.DroppingLoops(twoSpeakers).Count);
    }

    [Theory]
    [InlineData("[Music]", true)]
    [InlineData("(laughs)", true)]
    [InlineData("...", true)]
    [InlineData("Thank you.", false)]
    public void SoundAnnotationsAreNotWords(string text, bool annotation) => Assert.Equal(annotation, TranscriptRules.IsAnnotation(text));

    [Fact]
    public void LinesOverSilenceAreDropped()
    {
        var clip = Join(Silence(1), Tone(1));
        Assert.False(TranscriptRules.Keep(new RecognizedLine(0, 1, "Bye.", 0.1f), clip));
        Assert.True(TranscriptRules.Keep(new RecognizedLine(1, 2, "Bye.", 0.1f), clip));
    }
}
