using System.Buffers.Binary;
using System.Text;

namespace Earshot.Core;

/// <summary>A track written as it comes (32-bit float, 16 kHz mono, no header), so a crash or a power cut loses only the
/// last fraction of a second. Turned into Audio.m4a once the recording stops.</summary>
public sealed class RawTrack : IDisposable
{
    readonly FileStream stream;
    readonly object gate = new();
    long samples;

    public string Path { get; }
    public double Seconds { get { lock (gate) return samples / (double)Chunker.Rate; } }

    public RawTrack(string path)
    {
        Path = path;
        stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read, 1 << 16);
        samples = stream.Length / 4;
    }

    public void Append(ReadOnlySpan<float> data)
    {
        if (data.IsEmpty) return;
        var bytes = new byte[data.Length * 4];
        for (var i = 0; i < data.Length; i++) BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(i * 4), data[i]);
        lock (gate)
        {
            stream.Write(bytes);
            stream.Flush();
            samples += data.Length;
        }
    }

    /// <summary>Silence up to <paramref name="seconds"/>, so this track stays in step with the other one.</summary>
    public void PadTo(double seconds)
    {
        var missing = (long)(seconds * Chunker.Rate) - (long)(Seconds * Chunker.Rate);
        if (missing > 0) Append(new float[missing]);
    }

    public void Dispose()
    {
        lock (gate) stream.Dispose();
    }

    public static float[] Read(string path)
    {
        if (!File.Exists(path)) return Array.Empty<float>();
        var bytes = File.ReadAllBytes(path);
        var output = new float[bytes.Length / 4];
        for (var i = 0; i < output.Length; i++) output[i] = BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(i * 4));
        return output;
    }
}

/// <summary>Turns sound at any rate into 16 kHz, a buffer at a time, with no click between buffers. Going down, each
/// output sample is the average of the input it covers, which keeps the high end from folding back into speech.</summary>
public sealed class Resampler
{
    readonly double step;
    readonly List<float> buffer = new();
    double position;

    public Resampler(int inputRate, int outputRate = Chunker.Rate) => step = inputRate / (double)outputRate;

    public float[] Process(ReadOnlySpan<float> input)
    {
        foreach (var x in input) buffer.Add(x);
        var output = new List<float>();
        if (step >= 1)
        {
            while (position + step <= buffer.Count)
            {
                int a = (int)position, b = Math.Max(a + 1, (int)(position + step));
                double sum = 0;
                for (var i = a; i < b; i++) sum += buffer[i];
                output.Add((float)(sum / (b - a)));
                position += step;
            }
        }
        else
        {
            while (position + 1 < buffer.Count)
            {
                int a = (int)position;
                var f = (float)(position - a);
                output.Add(buffer[a] * (1 - f) + buffer[a + 1] * f);
                position += step;
            }
        }
        var drop = Math.Min((int)position, buffer.Count);
        buffer.RemoveRange(0, drop);
        position -= drop;
        return output.ToArray();
    }

    /// <summary>A whole recording in one go.</summary>
    public static float[] To16k(float[] samples, int rate) =>
        rate == Chunker.Rate ? samples : new Resampler(rate).Process(samples);

    /// <summary>Interleaved frames to mono (the mean of the channels).</summary>
    public static float[] Mono(ReadOnlySpan<float> interleaved, int channels)
    {
        if (channels <= 1) return interleaved.ToArray();
        var output = new float[interleaved.Length / channels];
        for (var f = 0; f < output.Length; f++)
        {
            float sum = 0;
            for (var c = 0; c < channels; c++) sum += interleaved[f * channels + c];
            output[f] = sum / channels;
        }
        return output;
    }

    /// <summary>The two tracks summed for Audio.m4a, each at full level, kept within [-1, 1].</summary>
    public static float[] Mix(float[] a, float[] b)
    {
        var output = new float[Math.Max(a.Length, b.Length)];
        for (var i = 0; i < output.Length; i++)
        {
            var x = (i < a.Length ? a[i] : 0) + (i < b.Length ? b[i] : 0);
            output[i] = Math.Clamp(x, -1f, 1f);
        }
        return output;
    }
}

/// <summary>WAV files: 16-bit or 32-bit float PCM in, 16-bit PCM out.</summary>
public static class WavFile
{
    /// <summary>Any PCM WAV file as 16 kHz mono samples.</summary>
    public static float[] Read16kMono(string path)
    {
        using var reader = new BinaryReader(File.OpenRead(path));
        if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "RIFF") throw new InvalidDataException("Not a WAV file");
        reader.ReadInt32();
        if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "WAVE") throw new InvalidDataException("Not a WAV file");
        int format = 0, channels = 0, rate = 0, bits = 0;
        while (reader.BaseStream.Position + 8 <= reader.BaseStream.Length)
        {
            var id = Encoding.ASCII.GetString(reader.ReadBytes(4));
            var size = reader.ReadInt32();
            if (id == "fmt ")
            {
                format = reader.ReadInt16(); channels = reader.ReadInt16(); rate = reader.ReadInt32();
                reader.ReadInt32(); reader.ReadInt16(); bits = reader.ReadInt16();
                if (format == 0xFFFE && size >= 26) { reader.ReadInt16(); reader.ReadInt16(); reader.ReadInt32(); format = reader.ReadInt16(); reader.ReadBytes(14); }
                else reader.ReadBytes(size - 16);
            }
            else if (id == "data")
            {
                var data = reader.ReadBytes(Math.Min(size, (int)(reader.BaseStream.Length - reader.BaseStream.Position)));
                float[] interleaved;
                if (format == 3 && bits == 32)
                {
                    interleaved = new float[data.Length / 4];
                    for (var i = 0; i < interleaved.Length; i++) interleaved[i] = BinaryPrimitives.ReadSingleLittleEndian(data.AsSpan(i * 4));
                }
                else if (format == 1 && bits == 16)
                {
                    interleaved = new float[data.Length / 2];
                    for (var i = 0; i < interleaved.Length; i++) interleaved[i] = BinaryPrimitives.ReadInt16LittleEndian(data.AsSpan(i * 2)) / 32768f;
                }
                else throw new InvalidDataException($"Unsupported WAV format {format}, {bits} bits");
                return Resampler.To16k(Resampler.Mono(interleaved, channels), rate);
            }
            else reader.ReadBytes(size + (size & 1));
        }
        throw new InvalidDataException("No audio data in the WAV file");
    }

    /// <summary>16-bit mono WAV, used when Windows has no AAC encoder for Audio.m4a.</summary>
    public static void Write16(string path, float[] samples, int rate = Chunker.Rate)
    {
        using var writer = new BinaryWriter(File.Create(path));
        var dataBytes = samples.Length * 2;
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + dataBytes);
        writer.Write(Encoding.ASCII.GetBytes("WAVE"));
        writer.Write(Encoding.ASCII.GetBytes("fmt ")); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2);
        writer.Write((short)2); writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(dataBytes);
        foreach (var s in samples) writer.Write((short)Math.Round(Math.Clamp(s, -1f, 1f) * 32767));
    }
}
