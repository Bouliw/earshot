namespace Earshot.Core;

/// <summary>Takes the PC's sound back out of the microphone. With speakers rather than headphones, the microphone also
/// hears the other side of the call, a moment after the PC plays it. Both tracks are kept whole: the PC's track says what
/// the speakers played, an adaptive filter learns how the room carries it to the microphone, and that estimate is taken
/// away, so the user's own voice stays even while the other side is talking (cutting someone off is transcribed too).
/// With headphones there is no echo to find and the microphone is left exactly as recorded.</summary>
public sealed class EchoCanceller
{
    public const int Block = 256;                 // 16 ms
    const int Size = 2 * Block, Bins = Block + 1;
    const int Partitions = 20;                    // the filter spans 320 ms of the room
    const int Lead = 2 * Block;                   // and starts 32 ms before the strongest echo
    const float Step = 0.5f;
    const float Floor = Size * Partitions * 1e-6f; // a PC sound under -60 dBFS teaches the filter nothing
    const double WarmUpSeconds = 60;
    const int Constrain = 4;

    readonly Action<long, float[]> readReference;
    readonly Fft fft = new(Size);
    readonly float[] workRe = new float[Size], workIm = new float[Size], time = new float[Size];
    // Spectra of the PC's sound, one per block, kept by block number modulo the number of partitions.
    readonly float[][] xRe = Jagged(), xIm = Jagged();
    readonly long[] xBlock = Enumerable.Repeat(long.MinValue, Partitions).ToArray();
    readonly double[] xEnergy = new double[Partitions];
    // Two filters: the background one learns all the time, the foreground one (the one heard) only takes what the
    // background learned once it does better. While both people talk the background goes astray; the output does not.
    readonly float[][] fgRe = Jagged(), fgIm = Jagged(), bgRe = Jagged(), bgIm = Jagged();
    readonly float[] spanPower = new float[Bins];
    readonly float[] yRe = new float[Bins], yIm = new float[Bins], eRe = new float[Bins], eIm = new float[Bins];
    readonly float[] gRe = new float[Bins], gIm = new float[Bins];
    readonly float[] echoFg = new float[Block], errorFg = new float[Block], echoBg = new float[Block], errorBg = new float[Block];
    double energyMic, energyFg, energyBg;
    int? offset;
    int lastLag;

    // What the filter leaves (speakers that distort, a room that changes) is turned down where it is louder than the voice.
    readonly float[] window = SqrtHann(Size);
    readonly float[] lastError = new float[Block], lastEcho = new float[Block], tail = new float[Block];
    readonly float[] pRe = new float[Bins], pIm = new float[Bins], qRe = new float[Bins], qIm = new float[Bins];
    readonly float[] errorAvg = new float[Bins], echoAvg = new float[Bins], residual = new float[Bins], gain = new float[Bins];
    double pey, pyy;
    float leak = 0.25f;
    readonly float[] output = new float[Block];

    /// <param name="readReference">Fills the array with the PC's sound from a sample number on (silence outside the recording).</param>
    public EchoCanceller(Action<long, float[]> readReference)
    {
        this.readReference = readReference;
        Array.Fill(gain, 1f);
    }

    /// <summary>The microphone with the PC's sound taken out. <paramref name="reference"/> is the PC's track, on the same
    /// clock. Returns <paramref name="mic"/> itself when no echo of the PC is found in it (headphones).</summary>
    public static float[] Clean(float[] mic, float[] reference)
    {
        if (mic.Length == 0 || reference.Length == 0) return mic;
        var track = EchoDelay.Track(reference, mic);
        if (track.Count == 0) return mic;
        var canceller = new EchoCanceller((start, destination) =>
        {
            Array.Clear(destination);
            var from = Math.Max(0, start);
            var to = Math.Min(reference.Length, start + destination.Length);
            if (to > from) Array.Copy(reference, from, destination, from - start, to - from);
        });
        var blocks = (mic.Length + Block - 1) / Block;
        var block = new float[Block];
        var next = 0;
        int LagAt(long b)
        {
            var t = b * Block;
            while (next + 1 < track.Count && Math.Abs(track[next + 1].Sample - t) <= Math.Abs(track[next].Sample - t)) next++;
            return track[next].Lag;
        }
        void Fill(long b)
        {
            Array.Clear(block);
            var from = b * Block;
            if (from < mic.Length) Array.Copy(mic, from, block, 0, Math.Min(Block, mic.Length - from));
        }

        // A first look at the start, so the opening sentences are cleaned as well as the rest.
        var warm = Math.Min(blocks, (int)(WarmUpSeconds * Chunker.Rate / Block));
        for (var b = 0; b < warm; b++) { Fill(b); canceller.Process(block, b, LagAt(b)); }
        canceller.Restart();
        next = 0;

        var cleaned = new float[mic.Length];
        for (var b = 0; b <= blocks; b++)  // one more block: the post-filter hands each block back one block later
        {
            Fill(b);
            var done = canceller.Process(block, b, LagAt(b));
            if (b == 0) continue;
            var at = (b - 1) * Block;
            Array.Copy(done, 0, cleaned, at, Math.Min(Block, mic.Length - at));
        }
        return cleaned;
    }

    /// <summary>Takes block <paramref name="index"/> of the microphone (<see cref="Block"/> samples) and returns the
    /// cleaned block before it. <paramref name="lag"/>: how many samples after the PC plays a sound the microphone hears it.</summary>
    public float[] Process(float[] mic, long index, int lag)
    {
        Align(lag);
        var r = index - offset!.Value / Block;
        double span = 0;
        for (var k = 0; k < Partitions; k++) span += Reference(r - k);
        Estimate(fgRe, fgIm, r, echoFg);
        Estimate(bgRe, bgIm, r, echoBg);
        double d = 0, f = 0, g = 0;
        for (var i = 0; i < Block; i++)
        {
            errorFg[i] = mic[i] - echoFg[i];
            errorBg[i] = mic[i] - echoBg[i];
            d += mic[i] * mic[i];
            f += errorFg[i] * errorFg[i];
            g += errorBg[i] * errorBg[i];
        }
        energyMic = 0.8 * energyMic + 0.2 * d;
        energyFg = 0.8 * energyFg + 0.2 * f;
        energyBg = 0.8 * energyBg + 0.2 * g;
        if (span > Floor / 2)
        {
            Adapt(r);
            if (energyBg < 0.8 * energyFg && energyBg < energyMic)
            {
                Copy(bgRe, bgIm, fgRe, fgIm);
                energyFg = energyBg;
            }
            else if (energyBg > 4 * energyMic && energyBg > 4 * energyFg)
            {
                Copy(fgRe, fgIm, bgRe, bgIm);
                energyBg = energyFg;
            }
        }
        return PostFilter();
    }

    /// <summary>Starts a new pass over the recording, keeping what was learned about the room.</summary>
    public void Restart()
    {
        Array.Clear(lastError); Array.Clear(lastEcho); Array.Clear(tail); Array.Clear(residual);
        Array.Fill(gain, 1f);
    }

    /// <summary>Moves the filter when the echo comes noticeably earlier or later (a Bluetooth headset, clocks drifting).</summary>
    void Align(int lag)
    {
        var target = (int)Math.Floor((lag - Lead) / (double)Block) * Block;
        if (offset is not { } current) { offset = target; lastLag = lag; return; }
        var jump = lag - lastLag;
        lastLag = lag;
        var into = lag - current;
        var moveFrame = into < Block || into >= 4 * Block;
        // Under 16 ms it is the estimate hesitating between the direct sound and a reflection: the filter covers both.
        var jumped = Math.Abs(jump) > Block;
        if (!moveFrame && !jumped) return;
        var next = moveFrame ? target : current;
        // What was learned about the room stays. When the echo drifted slowly, the filter followed it and only the
        // frame moves; when it jumped (a headset reconnected), the filter jumps with it.
        var shift = next - current - (jumped ? jump : 0);
        if (shift != 0)
        {
            ShiftTaps(fgRe, fgIm, shift);
            ShiftTaps(bgRe, bgIm, shift);
        }
        offset = next;
    }

    /// <summary>The filter, as one impulse response, moved <paramref name="samples"/> earlier.</summary>
    void ShiftTaps(float[][] re, float[][] im, int samples)
    {
        var taps = new float[Partitions * Block];
        for (var k = 0; k < Partitions; k++)
        {
            ToTime(re[k], im[k], time);
            Array.Copy(time, 0, taps, k * Block, Block);
        }
        for (var k = 0; k < Partitions; k++)
        {
            Array.Clear(time);
            for (var i = 0; i < Block; i++)
            {
                var from = k * Block + i + samples;
                if (from >= 0 && from < taps.Length) time[i] = taps[from];
            }
            ToSpectrum(time, re[k], im[k]);
        }
    }

    static int Slot(long block) => (int)(((block % Partitions) + Partitions) % Partitions);

    double Reference(long block)
    {
        var slot = Slot(block);
        if (xBlock[slot] == block) return xEnergy[slot];
        readReference((block - 1) * Block, time);
        double energy = 0;
        for (var i = Block; i < Size; i++) energy += time[i] * time[i];
        ToSpectrum(time, xRe[slot], xIm[slot]);
        xBlock[slot] = block;
        xEnergy[slot] = energy;
        return energy;
    }

    void Estimate(float[][] wRe, float[][] wIm, long r, float[] echo)
    {
        Array.Clear(yRe); Array.Clear(yIm);
        for (var k = 0; k < Partitions; k++)
        {
            var s = Slot(r - k);
            float[] ar = wRe[k], ai = wIm[k], br = xRe[s], bi = xIm[s];
            for (var j = 0; j < Bins; j++)
            {
                yRe[j] += ar[j] * br[j] - ai[j] * bi[j];
                yIm[j] += ar[j] * bi[j] + ai[j] * br[j];
            }
        }
        ToTime(yRe, yIm, time);
        Array.Copy(time, Block, echo, 0, Block);
    }

    /// <summary>One step of the background filter (partitioned frequency-domain NLMS, normalized by the PC's power).</summary>
    void Adapt(long r)
    {
        Array.Clear(time, 0, Block);
        Array.Copy(errorBg, 0, time, Block, Block);
        ToSpectrum(time, eRe, eIm);
        Array.Clear(gRe);
        for (var k = 0; k < Partitions; k++)
        {
            var s = Slot(r - k);
            for (var j = 0; j < Bins; j++) gRe[j] += xRe[s][j] * xRe[s][j] + xIm[s][j] * xIm[s][j];
        }
        for (var j = 0; j < Bins; j++) spanPower[j] = 0.5f * spanPower[j] + 0.5f * gRe[j];
        for (var k = 0; k < Partitions; k++)
        {
            var s = Slot(r - k);
            float[] xr = xRe[s], xi = xIm[s];
            for (var j = 0; j < Bins; j++)
            {
                var mu = Step / (spanPower[j] + Floor);
                gRe[j] = mu * (xr[j] * eRe[j] + xi[j] * eIm[j]);
                gIm[j] = mu * (xr[j] * eIm[j] - xi[j] * eRe[j]);
            }
            float[] wr = bgRe[k], wi = bgIm[k];
            for (var j = 0; j < Bins; j++) { wr[j] += gRe[j]; wi[j] += gIm[j]; }
            // Only the first half of the taps is a filter of one block: the rest would wrap around. Trimmed on a
            // quarter of the partitions each block, in turn (four times faster, and the filter learns as well).
            if (Slot(r + k) % Constrain != 0) continue;
            ToTime(wr, wi, time);
            Array.Clear(time, Block, Block);
            ToSpectrum(time, wr, wi);
        }
    }

    static void Copy(float[][] fromRe, float[][] fromIm, float[][] toRe, float[][] toIm)
    {
        for (var k = 0; k < Partitions; k++)
        {
            Array.Copy(fromRe[k], toRe[k], Bins);
            Array.Copy(fromIm[k], toIm[k], Bins);
        }
    }

    /// <summary>Turns down, frequency by frequency, what is left of the echo where it is louder than the user's voice.
    /// How much is left is measured as it goes: the part of the output that rises and falls with the echo estimate.</summary>
    float[] PostFilter()
    {
        for (var i = 0; i < Block; i++)
        {
            time[i] = lastError[i] * window[i];
            time[i + Block] = errorFg[i] * window[i + Block];
        }
        ToSpectrum(time, pRe, pIm);
        for (var i = 0; i < Block; i++)
        {
            time[i] = lastEcho[i] * window[i];
            time[i + Block] = echoFg[i] * window[i + Block];
        }
        ToSpectrum(time, qRe, qIm);
        Array.Copy(errorFg, lastError, Block);
        Array.Copy(echoFg, lastEcho, Block);

        double echoTotal = 0;
        for (var j = 0; j < Bins; j++) echoTotal += qRe[j] * qRe[j] + qIm[j] * qIm[j];
        if (echoTotal > 1e-3)
        {
            double covariance = 0, variance = 0;
            for (var j = 0; j < Bins; j++)
            {
                float ep = pRe[j] * pRe[j] + pIm[j] * pIm[j], yp = qRe[j] * qRe[j] + qIm[j] * qIm[j];
                errorAvg[j] = 0.9f * errorAvg[j] + 0.1f * ep;
                echoAvg[j] = 0.9f * echoAvg[j] + 0.1f * yp;
                double de = ep - errorAvg[j], dy = yp - echoAvg[j];
                covariance += de * dy;
                variance += dy * dy;
            }
            pey = 0.95 * pey + 0.05 * covariance;
            pyy = 0.95 * pyy + 0.05 * variance;
            if (pyy > 0) leak = (float)Math.Clamp(pey / pyy, 0.005, 0.5);
        }
        for (var j = 0; j < Bins; j++)
        {
            float ep = pRe[j] * pRe[j] + pIm[j] * pIm[j], yp = qRe[j] * qRe[j] + qIm[j] * qIm[j];
            residual[j] = Math.Max(leak * yp, 0.7f * residual[j]);
            var g = Math.Clamp(1 - 2 * residual[j] / (ep + 1e-12f), 0.1f, 1f);
            gain[j] = Math.Max(g, 0.6f * gain[j]);
            pRe[j] *= gain[j];
            pIm[j] *= gain[j];
        }
        ToTime(pRe, pIm, time);
        for (var i = 0; i < Block; i++)
        {
            output[i] = tail[i] + time[i] * window[i];
            tail[i] = time[i + Block] * window[i + Block];
        }
        return output;
    }

    void ToSpectrum(float[] samples, float[] re, float[] im)
    {
        Array.Copy(samples, workRe, Size);
        Array.Clear(workIm);
        fft.Forward(workRe, workIm);
        Array.Copy(workRe, re, Bins);
        Array.Copy(workIm, im, Bins);
    }

    void ToTime(float[] re, float[] im, float[] samples)
    {
        for (var j = 0; j < Bins; j++) { workRe[j] = re[j]; workIm[j] = im[j]; }
        workIm[0] = 0;
        workIm[Block] = 0;
        for (var j = Bins; j < Size; j++) { workRe[j] = re[Size - j]; workIm[j] = -im[Size - j]; }
        fft.Inverse(workRe, workIm);
        Array.Copy(workRe, samples, Size);
    }

    static float[][] Jagged() => Enumerable.Range(0, Partitions).Select(_ => new float[Bins]).ToArray();

    static float[] SqrtHann(int n) => Enumerable.Range(0, n).Select(i => (float)Math.Sqrt(0.5 - 0.5 * Math.Cos(2 * Math.PI * i / n))).ToArray();
}

/// <summary>How long after the PC plays a sound the microphone hears it: from a few milliseconds (laptop speakers) to a
/// few hundred (Bluetooth), and it can drift over a long call. Found by cross-correlating the two tracks, whitened
/// (GCC-PHAT) so the room's reverberation does not blur the peak, on 4 s windows every 2 s.</summary>
public static class EchoDelay
{
    const int Factor = 4, Rate = Chunker.Rate / Factor;  // 4 kHz is plenty to find a delay
    public const int Window = 16_384;                    // 4.1 s
    const int Before = Rate / 25;                        // 40 ms: the two clocks may put the echo a little early
    const int After = Rate * 6 / 5;                      // 1.2 s
    const int Size = 32_768;
    /// <summary>How far the correlation peak must stand above the rest. Without an echo (headphones) it stays near 4.</summary>
    public const float MinConfidence = 8f;

    /// <summary>Where an echo was found: at sample <c>Sample</c> of the recording (16 kHz), the microphone hears the PC
    /// <c>Lag</c> samples late. Empty when the microphone never hears the PC.</summary>
    public static List<(long Sample, int Lag)> Track(float[] reference, float[] mic)
    {
        var r = Decimate(reference);
        var m = Decimate(mic);
        var smoothed = new List<(long Sample, int Lag)>();
        var length = Math.Min(Window, r.Length);
        if (length < Rate) return smoothed;
        var fft = new Fft(Size);
        var estimates = new List<(long Sample, int Lag, float Confidence)>();
        for (var start = 0; start + length <= r.Length; start += length / 2)
        {
            if (Estimate(fft, r, start, length, m) is { } e && e.Confidence >= MinConfidence)
                estimates.Add(((start + length / 2L) * Factor, e.Lag, e.Confidence));
        }
        // Noise can stand out once by chance; an echo shows again at about the same delay (or very clearly).
        var found = estimates
            .Where(e => e.Confidence >= 2 * MinConfidence || estimates.Count(o => o != e && Math.Abs(o.Lag - e.Lag) <= EchoCanceller.Block) > 0)
            .Select(e => (e.Sample, e.Lag)).ToList();
        // A lone estimate far from its neighbours is noise: each one becomes the median of three, and the first and
        // last take their neighbour's. A real change of delay shows in two estimates in a row.
        for (var i = 0; i < found.Count; i++)
        {
            var lag = found[i].Lag;
            if (found.Count >= 3)
            {
                if (i == 0 || i == found.Count - 1)
                {
                    var neighbour = found[i == 0 ? 1 : i - 1].Lag;
                    if (Math.Abs(lag - neighbour) > EchoCanceller.Block) lag = neighbour;
                }
                else
                {
                    lag = new[] { found[i - 1].Lag, lag, found[i + 1].Lag }.OrderBy(l => l).ElementAt(1);
                }
            }
            smoothed.Add((found[i].Sample, lag));
        }
        return smoothed;
    }

    /// <summary>The lag (in 16 kHz samples) of the echo of <paramref name="reference"/>[start, start + length) in
    /// <paramref name="mic"/> (both at 4 kHz), and how clearly it stands out. Null when the PC is quiet there.</summary>
    public static (int Lag, float Confidence)? Estimate(Fft fft, float[] reference, int start, int length, float[] mic)
    {
        // The PC must be talking for a good part of the window, or there is nothing to find.
        var active = 0;
        var frames = length / (Rate / 10);
        for (var f = 0; f < frames; f++)
            if (Chunker.Rms(reference, start + f * Rate / 10, start + (f + 1) * Rate / 10) > 0.003f) active++;
        if (frames == 0 || active * 5 < frames) return null;

        var aRe = new float[Size]; var aIm = new float[Size];
        var bRe = new float[Size]; var bIm = new float[Size];
        Array.Copy(reference, start, aRe, 0, length);
        double micEnergy = 0;
        for (var i = 0; i < length + Before + After; i++)
        {
            var at = start - Before + i;
            if (at < 0 || at >= mic.Length) continue;
            bRe[i] = mic[at];
            micEnergy += mic[at] * mic[at];
        }
        if (micEnergy < 1e-8 * length) return null;
        fft.Forward(aRe, aIm);
        fft.Forward(bRe, bIm);
        int low = (int)(150.0 * Size / Rate), high = (int)(1900.0 * Size / Rate);
        for (var k = 0; k <= Size / 2; k++)
        {
            float zr = 0, zi = 0;
            if (k >= low && k <= high)
            {
                // conj(reference) × microphone, whitened (β-PHAT)
                zr = aRe[k] * bRe[k] + aIm[k] * bIm[k];
                zi = aRe[k] * bIm[k] - aIm[k] * bRe[k];
                var weight = 1 / (MathF.Pow(zr * zr + zi * zi, 0.4f) + 1e-20f);
                zr *= weight; zi *= weight;
            }
            aRe[k] = zr; aIm[k] = zi;
            if (k > 0 && k < Size / 2) { aRe[Size - k] = zr; aIm[Size - k] = -zi; }
        }
        fft.Inverse(aRe, aIm);
        var span = Before + After;
        int best = 0;
        double sum = 0;
        for (var i = 0; i <= span; i++)
        {
            sum += aRe[i] * aRe[i];
            if (aRe[i] > aRe[best]) best = i;
        }
        var rms = Math.Sqrt(sum / (span + 1));
        if (rms <= 0) return null;
        // Between two samples at 4 kHz: the top of the parabola through the peak and its neighbours.
        double between = 0;
        if (best > 0 && best < span)
        {
            double a = aRe[best - 1], b = aRe[best], c = aRe[best + 1], curve = a - 2 * b + c;
            if (curve < 0) between = Math.Clamp(0.5 * (a - c) / curve, -0.5, 0.5);
        }
        return ((int)Math.Round((best - Before + between) * Factor), (float)(aRe[best] / rms));
    }

    /// <summary>16 kHz to 4 kHz, averaging each four samples.</summary>
    public static float[] Decimate(float[] samples)
    {
        var output = new float[samples.Length / Factor];
        for (var i = 0; i < output.Length; i++)
            output[i] = (samples[Factor * i] + samples[Factor * i + 1] + samples[Factor * i + 2] + samples[Factor * i + 3]) / Factor;
        return output;
    }
}

/// <summary>The microphone while the other side talks. What it hears then is either the user (cutting in, a quick
/// "yes") or the call itself: a faint copy through headphones, or what the echo canceller leaves. Whisper turns that copy
/// into lines nobody said, close to the other side's words but not close enough for <see cref="EchoLines"/>. Two signs
/// give it away: it is much quieter than the user's own voice, and its loudness follows the call's, syllable by
/// syllable, a moment later. A stretch heard over the call is kept unless it shows one of them: the user cutting in
/// speaks at their usual level, with a rhythm of their own.</summary>
public static class EchoLeak
{
    public const int Frame = 320;          // 20 ms
    const int Latest = 60, Earliest = -2;  // heard up to 1.2 s after the PC plays it (Bluetooth), or 40 ms before
    /// <summary>A stretch whose loudest second stays under this share of the user's usual level is the call (about -9 dB).</summary>
    public const float QuietShare = 0.35f;
    /// <summary>A stretch whose loudness follows the call's at least this closely (correlation) is the call.</summary>
    public const float FollowShare = 0.6f;

    /// <summary>The pieces of the microphone (<paramref name="mic"/>, on the PC's clock) worth transcribing, given the
    /// PC's track.</summary>
    public static List<Piece> Keeping(IReadOnlyList<Piece> pieces, float[] mic, float[] reference)
    {
        if (pieces.Count == 0 || mic.Length == 0 || reference.Length == 0) return pieces.ToList();
        var m = Envelope(mic);
        var r = Envelope(reference);
        var sounding = r.Where(v => v > 1e-4f).OrderBy(v => v).ToArray();
        if (sounding.Length == 0) return pieces.ToList();
        var talking = sounding[sounding.Length * 9 / 10] / 10;  // within 20 dB of the call's loud moments
        // Whether the microphone may be hearing the call at each 20 ms: it talked in the last 1.2 s.
        var heard = new bool[m.Length];
        var lastOn = int.MinValue / 2;
        for (var i = 0; i < m.Length; i++)
        {
            if (i < r.Length && r[i] > talking) lastOn = i;
            heard[i] = i - lastOn <= Latest;
        }
        (int From, int To) Frames(Piece p)
        {
            var a = Math.Max(0, (int)(p.Start * Chunker.Rate) / Frame);
            var b = Math.Min(m.Length, (int)(p.End * Chunker.Rate) / Frame);
            return (a, Math.Max(a, b));
        }
        bool OverCall(Piece p)
        {
            var (a, b) = Frames(p);
            if (b <= a) return false;
            var n = 0;
            for (var i = a; i < b; i++) if (heard[i]) n++;
            return n * 10 >= (b - a) * 3;
        }
        // The user's usual level: the loudest second of what the microphone heard while the call was quiet.
        var alone = pieces.Where(p => !OverCall(p)).Select(p => Loudest(m, Frames(p))).OrderBy(v => v).ToList();
        float? usual = alone.Count >= 3 ? alone[alone.Count / 2] : null;
        // How late the microphone hears the call, over the whole recording; each piece is then only checked around it.
        var lag = Delay(m, r, talking);
        int low = Math.Max(Earliest, lag - 5), high = Math.Min(Latest, lag + 5);
        return pieces.Where(p =>
        {
            if (!OverCall(p)) return true;
            var f = Frames(p);
            if (usual is { } u && Loudest(m, f) < u * QuietShare) return false;
            return Follows(m, r, f, talking, low, high) < FollowShare;
        }).ToList();
    }

    /// <summary>The delay (in 20 ms) at which the microphone's loudness follows the call's best, over the whole recording.</summary>
    public static int Delay(float[] m, float[] r, float talking)
    {
        int best = 0;
        var bestScore = -2f;
        for (var lag = Earliest; lag <= Latest; lag++)
        {
            var score = Follows(m, r, (0, m.Length), talking, lag, lag);
            if (score > bestScore) { bestScore = score; best = lag; }
        }
        return best;
    }

    /// <summary>Loudness of each 20 ms.</summary>
    public static float[] Envelope(float[] s)
    {
        var output = new float[(s.Length + Frame - 1) / Frame];
        for (var k = 0; k < output.Length; k++) output[k] = Chunker.Rms(s, k * Frame, k * Frame + Frame);
        return output;
    }

    /// <summary>The loudest second of <paramref name="f"/> (all of it when shorter).</summary>
    public static float Loudest(float[] e, (int From, int To) f)
    {
        if (f.To <= f.From) return 0;
        var n = Math.Min(50, f.To - f.From);
        float sum = 0, best = 0;
        for (var i = f.From; i < f.To; i++)
        {
            sum += e[i] * e[i];
            if (i - n >= f.From) sum -= e[i - n] * e[i - n];
            if (i - f.From + 1 >= n) best = Math.Max(best, sum);
        }
        return (float)Math.Sqrt(Math.Max(best, 0) / n);
    }

    /// <summary>How closely the loudness of <paramref name="f"/> follows the call's at the best delay from
    /// <paramref name="low"/> to <paramref name="high"/> (in 20 ms), from -1 to 1, counted only where the call is talking
    /// (a reply that starts as the other side stops does not count) and over half a second at least (a shorter overlap
    /// tells nothing: 0).</summary>
    public static float Follows(float[] m, float[] r, (int From, int To) f, float talking, int low, int high)
    {
        var best = 0f;
        var x = new List<float>(f.To - f.From);
        var y = new List<float>(f.To - f.From);
        for (var lag = low; lag <= high; lag++)
        {
            x.Clear();
            y.Clear();
            for (var i = f.From; i < f.To; i++)
            {
                var j = i - lag;
                if (j < 0 || j >= r.Length || r[j] <= talking) continue;
                x.Add((float)Math.Log10(m[i] + 1e-4));
                y.Add((float)Math.Log10(r[j] + 1e-4));
            }
            if (x.Count < 25) continue;  // half a second at least
            best = Math.Max(best, Correlation(x, y));
        }
        return best;
    }

    static float Correlation(List<float> x, List<float> y)
    {
        float mx = x.Average(), my = y.Average();
        float sxy = 0, sxx = 0, syy = 0;
        for (var i = 0; i < x.Count; i++)
        {
            float dx = x[i] - mx, dy = y[i] - my;
            sxy += dx * dy;
            sxx += dx * dx;
            syy += dy * dy;
        }
        return sxx > 0 && syy > 0 ? sxy / (float)Math.Sqrt(sxx * syy) : 0;
    }
}

/// <summary>A last guard against echo: a line on the microphone whose words the other side said at that very moment
/// was the speakers, not the user. A line keeps its place unless 70 % of its words were in the other side's lines then.</summary>
public static class EchoLines
{
    const double Slack = 0.6;

    public static List<Segment> Dropping(IReadOnlyList<Segment> segments)
    {
        var others = segments.Where(s => s.Mic != true).ToList();
        if (others.Count == 0) return segments.ToList();
        return segments.Where(s => s.Mic != true || !IsEcho(s, others)).ToList();
    }

    public static bool IsEcho(Segment line, IReadOnlyList<Segment> others)
    {
        var words = Words(line.Text);
        if (words.Count == 0) return false;
        var heard = new Dictionary<string, int>();
        foreach (var other in others.Where(o => o.Start < line.End + Slack && o.End > line.Start - Slack))
            foreach (var w in Words(other.Text)) heard[w] = heard.GetValueOrDefault(w) + 1;
        if (heard.Count == 0) return false;
        var found = 0;
        foreach (var w in words)
        {
            if (!heard.TryGetValue(w, out var n) || n == 0) continue;
            heard[w] = n - 1;
            found++;
        }
        return found * 10 >= words.Count * 7;
    }

    static List<string> Words(string text)
    {
        var words = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (var c in text)
        {
            if (char.IsLetterOrDigit(c)) { current.Append(char.ToLowerInvariant(c)); continue; }
            if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words;
    }
}

/// <summary>Radix-2 fast Fourier transform, in place on separate real and imaginary parts.</summary>
public sealed class Fft
{
    readonly int size;
    readonly int[] reversed;
    readonly float[] cos, sin;

    public Fft(int size)
    {
        if (size < 2 || (size & (size - 1)) != 0) throw new ArgumentException("The size must be a power of two.", nameof(size));
        this.size = size;
        var bits = 0;
        while ((1 << bits) < size) bits++;
        reversed = new int[size];
        for (var i = 0; i < size; i++)
        {
            var r = 0;
            for (var b = 0; b < bits; b++) if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b);
            reversed[i] = r;
        }
        cos = new float[size / 2];
        sin = new float[size / 2];
        for (var i = 0; i < size / 2; i++)
        {
            cos[i] = (float)Math.Cos(2 * Math.PI * i / size);
            sin[i] = (float)Math.Sin(2 * Math.PI * i / size);
        }
    }

    public void Forward(float[] re, float[] im) => Run(re, im, -1);

    public void Inverse(float[] re, float[] im)
    {
        Run(re, im, 1);
        var scale = 1f / size;
        for (var i = 0; i < size; i++) { re[i] *= scale; im[i] *= scale; }
    }

    void Run(float[] re, float[] im, int sign)
    {
        for (var i = 0; i < size; i++)
        {
            var j = reversed[i];
            if (j > i) { (re[i], re[j]) = (re[j], re[i]); (im[i], im[j]) = (im[j], im[i]); }
        }
        for (var length = 2; length <= size; length <<= 1)
        {
            var half = length >> 1;
            var step = size / length;
            for (var start = 0; start < size; start += length)
            {
                for (var k = 0; k < half; k++)
                {
                    float wr = cos[k * step], wi = sign * sin[k * step];
                    int a = start + k, b = a + half;
                    float tr = wr * re[b] - wi * im[b], ti = wr * im[b] + wi * re[b];
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
        }
    }
}
