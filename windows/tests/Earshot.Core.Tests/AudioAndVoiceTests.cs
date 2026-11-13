using System.Reflection;
using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

public sealed class AudioAndVoiceTests
{
    public AudioAndVoiceTests() => L.Use("en");

    const int Rate = Chunker.Rate;

    static float[] Tone(double seconds, int rate = Rate, double hz = 220) =>
        Enumerable.Range(0, (int)(seconds * rate)).Select(i => (float)(0.1 * Math.Sin(2 * Math.PI * hz * i / rate))).ToArray();

    [Fact]
    public void LongPiecesAreCutAtTheQuietestMoment()
    {
        var samples = Tone(40);
        Array.Clear(samples, (int)(12.3 * Rate), Rate / 10);
        var pieces = Chunker.Split(new Piece(0, 40), samples, 15);
        Assert.All(pieces, p => Assert.True(p.Length <= 15.0001));
        Assert.InRange(pieces[0].End, 12.3, 12.45);
        Assert.Equal(40, pieces[^1].End);
    }

    [Fact]
    public void SpeechStretchesArePaddedAndJoined()
    {
        var samples = new float[10 * Rate];
        var pieces = Chunker.FromSpeech(new[] { (1.0, 2.0), (2.3, 3.0), (6.0, 7.0) }, samples, 15);
        Assert.Equal(2, pieces.Count);
        Assert.Equal((0.8, 3.2), (Math.Round(pieces[0].Start, 3), Math.Round(pieces[0].End, 3)));
        Assert.Equal((5.8, 7.2), (Math.Round(pieces[1].Start, 3), Math.Round(pieces[1].End, 3)));
    }

    [Fact]
    public void TurnsOfOneVoiceJoinAcrossShortPauses()
    {
        var samples = new float[20 * Rate];
        var turns = new[] { new VoiceTurn(0, 2, "S0"), new VoiceTurn(2.5, 4, "S0"), new VoiceTurn(4.2, 6, "S1"), new VoiceTurn(8, 9, "S1") };
        var pieces = Chunker.Pieces(turns, samples, 15);
        Assert.Equal(new[] { (0.0, 4.0, "S0"), (4.2, 6.0, "S1"), (8.0, 9.0, "S1") }, pieces.Select(p => (p.Start, p.End, p.Voice!)));
    }

    [Fact]
    public void ClipsArePaddedToJustOverASecond()
    {
        var clip = Chunker.Clip(Tone(5), new Piece(1, 1.5));
        Assert.Equal(17_600, clip.Length);
        Assert.Empty(Chunker.Clip(Tone(1), new Piece(3, 4)));
    }

    [Fact]
    public void OverlapsBelongToTheVoiceAlreadySpeaking()
    {
        var turns = Voices.Exclusive(new[] { new VoiceTurn(0, 3, "A"), new VoiceTurn(2, 5, "B"), new VoiceTurn(4.9, 5.05, "C") });
        Assert.Equal(new[] { (0.0, 3.0, "A"), (3.0, 5.0, "B") }, turns.Select(t => (t.Start, t.End, t.Voice)));
        Assert.Equal("B", Voices.Voice(2.5, 4.5, turns));
        Assert.Equal("B", Voices.Voice(5.5, 6, turns));
        Assert.Null(Voices.Voice(8, 9, turns));
    }

    [Fact]
    public void ASingleVoiceIsNamedOnlyWhenTheUserIsRecordedApart()
    {
        var turns = new[] { new VoiceTurn(0, 3, "S0") };
        Assert.Empty(Voices.Names(turns, Array.Empty<NameMark>(), withUser: false));
        Assert.Equal("Speaker 1", Voices.Names(turns, Array.Empty<NameMark>(), withUser: true)["S0"]);
        var marks = new[] { new NameMark { Time = 1, Name = "Ada" }, new NameMark { Time = 2, Name = "Ada" } };
        Assert.Equal("Ada", Voices.Names(turns, marks, withUser: false)["S0"]);
    }

    [Fact]
    public void SpeakersAreNumberedWithoutGaps()
    {
        var turns = new[] { new VoiceTurn(0, 2, "S0"), new VoiceTurn(2, 3, "S4"), new VoiceTurn(3, 6, "S2") };
        var lines = new[] { new Segment(0, 1.5, "a"), new Segment(4, 5, "b"), new Segment(6.5, 7, "c", "Me", true) };
        var labelled = Voices.Label(lines, turns, Array.Empty<NameMark>());
        Assert.Equal(new[] { "Speaker 1", "Speaker 2", "Me" }, labelled.Select(l => l.Speaker));
    }

    [Fact]
    public void ResamplingKeepsTheLengthAndTheTone()
    {
        var input = Tone(2, 48_000);
        var resampler = new Resampler(48_000);
        var output = resampler.Process(input.AsSpan(0, 30_001)).Concat(resampler.Process(input.AsSpan(30_001))).ToArray();
        Assert.InRange(output.Length, 2 * Rate - 2, 2 * Rate);
        Assert.InRange(Chunker.Rms(output, 0, output.Length), 0.065, 0.075);
        var up = Resampler.To16k(Tone(1, 8_000), 8_000);
        Assert.InRange(up.Length, Rate - 3, Rate);
    }

    [Fact]
    public void StereoBecomesMonoAndMixesStayInRange()
    {
        Assert.Equal(new[] { 0.5f, 0f }, Resampler.Mono(new[] { 1f, 0f, 0.5f, -0.5f }, 2));
        Assert.Equal(new[] { 1f, -1f, 0.25f }, Resampler.Mix(new[] { 0.8f, -0.9f }, new[] { 0.5f, -0.5f, 0.25f }));
    }

    [Fact]
    public void RawTracksSurviveAndCatchUp()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".pcm");
        try
        {
            using (var track = new RawTrack(path))
            {
                track.Append(new[] { 0.25f, -0.5f });
                track.PadTo(1);
                Assert.Equal(1, track.Seconds, 3);
            }
            using (var track = new RawTrack(path)) track.Append(new[] { 1f });
            var samples = RawTrack.Read(path);
            Assert.Equal(Rate + 1, samples.Length);
            Assert.Equal((0.25f, -0.5f, 0f, 1f), (samples[0], samples[1], samples[2], samples[^1]));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void WaveFilesRoundTrip()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            var tone = Tone(1);
            WavFile.Write16(path, tone);
            var back = WavFile.Read16kMono(path);
            Assert.Equal(tone.Length, back.Length);
            Assert.True(tone.Zip(back).All(p => Math.Abs(p.First - p.Second) < 0.0002));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void ModelsAreDownloadedOverHttpsWithKnownSizes()
    {
        var all = ModelCatalog.Whisper.Concat(new[] { ModelCatalog.VoiceActivity, ModelCatalog.Segmentation, ModelCatalog.Embedding }).ToList();
        Assert.All(all, m => Assert.StartsWith("https://", m.Url));
        Assert.All(all, m => Assert.True(m.Bytes > 100_000));
        Assert.Equal(all.Count, all.Select(m => m.FileName).Distinct().Count());
        Assert.Equal("ggml-large-v3-turbo.bin", ModelCatalog.WhisperModel(null).FileName);
        Assert.Equal("ggml-small.bin", ModelCatalog.WhisperModel("small").FileName);
        Assert.Equal("1.6 GB", ModelCatalog.Whisper[0].SizeText);
    }

    [Fact]
    public void EveryStringHasAFrenchVersion()
    {
        var same = new HashSet<string> { "AppName", "Sessions", "Ok" };
        var properties = typeof(L).GetProperties(BindingFlags.Public | BindingFlags.Static).Where(p => p.PropertyType == typeof(string) && !same.Contains(p.Name)).ToList();
        Assert.True(properties.Count > 40);
        try
        {
            L.Use("en");
            var english = properties.ToDictionary(p => p.Name, p => (string)p.GetValue(null)!);
            L.Use("fr");
            foreach (var p in properties)
            {
                var french = (string)p.GetValue(null)!;
                Assert.False(string.IsNullOrWhiteSpace(french), p.Name);
                Assert.NotEqual(english[p.Name], french);
            }
            Assert.Equal("Intervenant 2", L.Speaker(2));
            Assert.Equal("Moi", L.Me);
        }
        finally { L.Use("en"); }
    }
}
