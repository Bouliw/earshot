using System;
using System.IO;
using Earshot.Core;
using Earshot.Engines;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Earshot.Desktop.Audio;

/// <summary>Audio.m4a with Windows' own AAC encoder (Media Foundation). It only takes 44.1 or 48 kHz, so the 16 kHz
/// recording is resampled first. Windows N editions ship without it: the job then falls back on Audio.wav.</summary>
public sealed class AacEncoder : IAudioEncoder
{
    static bool started;

    public string Write(float[] samples, string folder)
    {
        if (!started) { MediaFoundationApi.Startup(); started = true; }
        var path = Path.Combine(folder, SessionStore.AudioName);
        var source = new ArraySampleProvider(samples, Chunker.Rate);
        var resampled = new WdlResamplingSampleProvider(source, 48_000);
        var pcm = new SampleToWaveProvider16(resampled);
        MediaFoundationEncoder.EncodeToAac(pcm, path, 96_000);
        if (!File.Exists(path) || new FileInfo(path).Length == 0) throw new IOException("The AAC encoder wrote nothing");
        return SessionStore.AudioName;
    }

    sealed class ArraySampleProvider : ISampleProvider
    {
        readonly float[] samples;
        int position;

        public ArraySampleProvider(float[] samples, int rate)
        {
            this.samples = samples;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(rate, 1);
        }

        public WaveFormat WaveFormat { get; }

        public int Read(float[] buffer, int offset, int count)
        {
            var n = Math.Min(count, samples.Length - position);
            if (n <= 0) return 0;
            Array.Copy(samples, position, buffer, offset, n);
            position += n;
            return n;
        }
    }
}
