using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

public sealed class EchoTests
{
    const int Rate = Chunker.Rate;

    /// <summary>Speech-like sound: bursts of coloured noise the length of syllables, with short pauses.</summary>
    static float[] Voice(double seconds, int seed, double pitch)
    {
        var random = new Random(seed);
        var output = new float[(int)(seconds * Rate)];
        double y1 = 0, y2 = 0, r = 0.97, w = 2 * Math.PI * pitch / Rate;
        var i = 0;
        while (i < output.Length)
        {
            var syllable = (int)((0.12 + 0.2 * random.NextDouble()) * Rate);
            var gap = (int)((0.03 + 0.1 * random.NextDouble()) * Rate);
            for (var k = 0; k < syllable && i < output.Length; k++, i++)
            {
                var y = random.NextDouble() * 2 - 1 + 2 * r * Math.Cos(w) * y1 - r * r * y2;
                y2 = y1;
                y1 = y;
                output[i] = (float)(y * Math.Sin(Math.PI * k / syllable));
            }
            i += gap;
        }
        var rms = Chunker.Rms(output, 0, output.Length);
        for (var k = 0; k < output.Length; k++) output[k] *= 0.1f / rms;
        return output;
    }

    /// <summary>What a microphone hears of the PC's speakers <paramref name="delay"/> samples later, with a few reflections.</summary>
    static float[] Room(float[] pc, int delay, float gain = 0.5f)
    {
        var taps = new (int At, float Gain)[] { (0, 1f), (37, 0.4f), (211, -0.2f), (900, 0.1f), (2300, -0.05f) };
        var output = new float[pc.Length];
        for (var t = 0; t < pc.Length; t++)
            foreach (var (at, g) in taps)
            {
                var from = t - delay - at;
                if (from >= 0) output[t] += gain * g * (float)Math.Tanh(1.5 * pc[from]) / 1.5f;
            }
        return output;
    }

    static float[] Add(params float[][] tracks)
    {
        var output = new float[tracks.Max(t => t.Length)];
        foreach (var t in tracks) for (var i = 0; i < t.Length; i++) output[i] += t[i];
        return output;
    }

    static float[] Place(float[] sound, double at, int length)
    {
        var output = new float[length];
        Array.Copy(sound, 0, output, (int)(at * Rate), Math.Min(sound.Length, length - (int)(at * Rate)));
        return output;
    }

    static double Energy(float[] s, double from, double to, float[]? minus = null)
    {
        double sum = 0;
        for (var i = (int)(from * Rate); i < (int)(to * Rate); i++)
        {
            var x = s[i] - (minus?[i] ?? 0);
            sum += x * x;
        }
        return sum;
    }

    static double Db(double ratio) => 10 * Math.Log10(ratio);

    [Fact]
    public void ThePcsVoiceIsTakenOutOfTheMicrophoneAndTheUsersStays()
    {
        var length = 20 * Rate;
        var pc = Place(Voice(14, 1, 600), 0, length);  // the other side talks for 14 s, then stops
        var user = Add(Place(Voice(3, 2, 1500), 8, length), Place(Voice(3, 3, 1300), 15, length));
        var mic = Add(Room(pc, 1280), user);  // laptop speakers, 80 ms
        var cleaned = EchoCanceller.Clean(mic, pc);

        // The other side alone: its echo is at least 20 dB down.
        Assert.True(Db(Energy(mic, 2, 7) / Energy(cleaned, 2, 7)) > 20);
        // Both at once (the user cuts in): the user's voice comes out at least 10 dB clearer than it was recorded.
        Assert.True(Db(Energy(mic, 8, 11, user) / Energy(cleaned, 8, 11, user)) > 10);
        // The user alone: left as it was.
        Assert.True(Db(Energy(user, 15, 18) / Energy(cleaned, 15, 18, user)) > 30);
    }

    [Fact]
    public void WithHeadphonesTheMicrophoneIsLeftAsRecorded()
    {
        var pc = Voice(12, 4, 700);
        var mic = Add(Place(Voice(4, 5, 1400), 3, pc.Length), Room(new float[pc.Length], 0));
        Assert.Same(mic, EchoCanceller.Clean(mic, pc));
    }

    [Theory]
    [InlineData(160)]    // 10 ms
    [InlineData(4000)]   // 250 ms: a Bluetooth speaker
    public void TheDelayOfTheEchoIsFound(int delay)
    {
        var pc = Voice(12, 6, 800);
        var lags = EchoDelay.Track(pc, Room(pc, delay)).Select(t => t.Lag).ToList();
        Assert.NotEmpty(lags);
        Assert.All(lags, lag => Assert.InRange(lag, delay - 8, delay + 8));
    }

    [Fact]
    public void TheMicrophonesLinesThatRepeatTheOtherSideAtThatMomentAreDropped()
    {
        var other = new Segment(10, 14, "Lundi on commence par la revue des incidents.", "Speaker 1");
        var echo = new Segment(10.2, 13.8, "lundi, on commence par la revue des incidents", "Me", true);
        var cutIn = new Segment(11, 12.5, "Attends, je ne suis pas là lundi.", "Me", true);
        var later = new Segment(30, 33, "Lundi on commence par la revue des incidents.", "Me", true);
        var kept = EchoLines.Dropping(new[] { other, echo, cutIn, later });
        Assert.Equal(new[] { other, cutIn, later }, kept);
    }

    static float[] Noise(int length, float level, int seed)
    {
        var random = new Random(seed);
        var output = new float[length];
        for (var i = 0; i < length; i++) output[i] = level * (float)(random.NextDouble() * 2 - 1);
        return output;
    }

    /// <summary>The call coming back faintly through headphones (30 dB down, 200 ms late): Whisper would write lines
    /// nobody said over it. The user cutting in, answering as the other side stops, or talking alone is kept.</summary>
    [Fact]
    public void TheCallsFaintCopyOnTheMicrophoneIsLeftOut()
    {
        var length = 32 * Rate;
        var pc = Place(Voice(14, 8, 650), 0, length);
        var mic = Add(Room(pc, 3200, 0.03f), Noise(length, 0.0005f, 13));
        foreach (var (at, seed) in new[] { (6.0, 9), (14.3, 10), (19.0, 11), (23.0, 12), (27.0, 14) })
            mic = Add(mic, Place(Voice(3, seed, 1300), at, length));
        var leak = new Piece(1, 5);
        var cutIn = new Piece(5.8, 9.2);
        var answer = new Piece(14.1, 17.5);
        var alone = new[] { 18.8, 22.8, 26.8 }.Select(s => new Piece(s, s + 3.4)).ToList();
        var kept = EchoLeak.Keeping(new[] { leak, cutIn, answer }.Concat(alone).ToList(), mic, pc);
        Assert.Equal(new[] { cutIn, answer }.Concat(alone), kept);
    }

    /// <summary>Without the user's voice heard alone to compare with (they only cut in), the rhythm is enough: what is
    /// left of laptop speakers after the canceller follows the call and goes; the user cutting in does not.</summary>
    [Fact]
    public void TheCallsCopyIsToldFromTheUserByItsRhythm()
    {
        var length = 16 * Rate;
        var pc = Place(Voice(16, 15, 700), 0, length);
        var mic = Add(Room(pc, 1280, 0.1f), Place(Voice(3, 16, 1400), 9, length), Noise(length, 0.0005f, 17));
        var cutIn = new Piece(8.8, 12.2);
        Assert.Equal(new[] { cutIn }, EchoLeak.Keeping(new[] { new Piece(2, 7), cutIn }, mic, pc));
    }

    [Fact]
    public void WhileTheCallIsSilentTheMicrophoneIsKept()
    {
        var length = 10 * Rate;
        var mic = Place(Voice(3, 18, 1200), 2, length);
        var pieces = new[] { new Piece(1.8, 5.2) };
        Assert.Equal(pieces, EchoLeak.Keeping(pieces, mic, new float[length]));
    }
}
