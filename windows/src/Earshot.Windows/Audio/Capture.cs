using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Earshot.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Earshot.Desktop.Audio;

/// <summary>A microphone Windows lists as active.</summary>
public sealed record MicrophoneDevice(string Id, string Name);

/// <summary>One capture stream (the PC's sound through WASAPI loopback, or a microphone) written to its own track at
/// 16 kHz mono as the sound comes.</summary>
sealed class TrackWriter : IDisposable
{
    readonly IWaveIn capture;
    readonly RawTrack track;
    readonly Resampler resampler;
    readonly WaveFormat format;
    float level;
    volatile bool closed;

    public RawTrack Track => track;
    /// <summary>The level of the last buffer (RMS), for the meters.</summary>
    public float Level => Volatile.Read(ref level);

    public TrackWriter(IWaveIn capture, string path)
    {
        this.capture = capture;
        track = new RawTrack(path);
        format = capture.WaveFormat;
        resampler = new Resampler(format.SampleRate);
        capture.DataAvailable += OnData;
    }

    public void Start() => capture.StartRecording();

    void OnData(object? sender, WaveInEventArgs e)
    {
        if (closed || e.BytesRecorded <= 0) return;
        try
        {
            var interleaved = Samples.FromBytes(e.Buffer, e.BytesRecorded, format);
            var mono = Resampler.Mono(interleaved, format.Channels);
            var samples = resampler.Process(mono);
            Volatile.Write(ref level, Chunker.Rms(samples, 0, samples.Length));
            track.Append(samples);
        }
        catch (ObjectDisposedException) { /* a last buffer after Stop */ }
        catch (IOException) { /* disk full: the recording keeps what it has */ }
    }

    public void Stop()
    {
        try { capture.StopRecording(); } catch (Exception) { /* already stopped (device removed) */ }
    }

    public void Dispose()
    {
        closed = true;
        capture.DataAvailable -= OnData;
        try { capture.Dispose(); } catch (Exception) { }
        track.Dispose();
    }
}

/// <summary>Records a call: the PC's sound (loopback of the default output) and the chosen microphone, on two separate
/// tracks, as on the Mac. Both tracks are kept in step with the clock: Windows sends nothing from the loopback while
/// the PC is silent, so silence is played to the output to keep it flowing, and any gap is filled with silence.</summary>
public sealed class Recorder : IDisposable
{
    TrackWriter? pc;
    TrackWriter? mic;
    WasapiOut? keepAlive;
    Timer? clock;
    readonly Stopwatch watch = new();

    public bool IsRecording { get; private set; }
    public TimeSpan Elapsed => watch.Elapsed;
    public float PcLevel => pc?.Level ?? 0;
    public float MicLevel => mic?.Level ?? 0;
    public bool HasMicrophone => mic != null;

    public static List<MicrophoneDevice> Microphones()
    {
        var list = new List<MicrophoneDevice>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
                list.Add(new MicrophoneDevice(device.ID, device.FriendlyName));
        }
        catch (Exception) { /* no audio service: an empty list */ }
        return list;
    }

    /// <param name="folder">The session folder the two tracks go to.</param>
    /// <param name="microphone">A device id, "" for the default microphone, or "none".</param>
    public void Start(string folder, string microphone)
    {
        if (IsRecording) return;
        Directory.CreateDirectory(folder);
        try
        {
            pc = new TrackWriter(new WasapiLoopbackCapture(), Path.Combine(folder, SessionStore.AppTrackName));
            if (microphone != "none") mic = OpenMicrophone(microphone, Path.Combine(folder, SessionStore.MicTrackName));
            KeepLoopbackFlowing();
            watch.Restart();
            pc.Start();
            mic?.Start();
            IsRecording = true;
            clock = new Timer(_ => CatchUp(), null, 1000, 1000);
        }
        catch (Exception)
        {
            CleanUp();
            throw;
        }
    }

    static TrackWriter? OpenMicrophone(string id, string path)
    {
        using var enumerator = new MMDeviceEnumerator();
        MMDevice? device = null;
        if (id.Length > 0)
        {
            try { device = enumerator.GetDevice(id); } catch (Exception) { device = null; }
        }
        if (device is null || device.State != DeviceState.Active)
        {
            if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console)) return null;
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        return new TrackWriter(new WasapiCapture(device) { ShareMode = AudioClientShareMode.Shared }, path);
    }

    /// <summary>Silence played to the default output: the loopback then delivers a steady stream, silent or not.</summary>
    void KeepLoopbackFlowing()
    {
        try
        {
            keepAlive = new WasapiOut(AudioClientShareMode.Shared, 200);
            keepAlive.Init(new SilenceProvider(WaveFormat.CreateIeeeFloatWaveFormat(48_000, 2)));
            keepAlive.Play();
        }
        catch (Exception)
        {
            keepAlive?.Dispose();
            keepAlive = null;  // the clock below fills the gaps instead
        }
    }

    /// <summary>A track more than a second behind the clock (no sound delivered, device lost) gets silence.</summary>
    void CatchUp()
    {
        try
        {
            var now = watch.Elapsed.TotalSeconds - 1;
            if (now <= 0) return;
            if (pc != null && pc.Track.Seconds < now) pc.Track.PadTo(now);
            if (mic != null && mic.Track.Seconds < now) mic.Track.PadTo(now);
        }
        catch (ObjectDisposedException) { }
        catch (IOException) { }
    }

    /// <summary>Stops both streams and evens the tracks out. Returns the duration in seconds.</summary>
    public double Stop()
    {
        if (!IsRecording) return 0;
        IsRecording = false;
        clock?.Dispose();
        clock = null;
        pc?.Stop();
        mic?.Stop();
        Thread.Sleep(150);  // the last buffers
        watch.Stop();
        var duration = Math.Max(pc?.Track.Seconds ?? 0, mic?.Track.Seconds ?? 0);
        pc?.Track.PadTo(duration);
        mic?.Track.PadTo(duration);
        CleanUp();
        return duration;
    }

    void CleanUp()
    {
        try { keepAlive?.Stop(); } catch (Exception) { }
        keepAlive?.Dispose();
        keepAlive = null;
        pc?.Dispose();
        mic?.Dispose();
        pc = null;
        mic = null;
    }

    public void Dispose()
    {
        if (IsRecording) Stop();
        CleanUp();
    }
}

static class Samples
{
    /// <summary>Capture bytes as interleaved floats, whatever the device's sample format.</summary>
    public static float[] FromBytes(byte[] buffer, int count, WaveFormat format)
    {
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible ext && ext.SubFormat == NAudio.Dmo.AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        switch (format.BitsPerSample)
        {
            case 32 when isFloat:
            {
                var output = new float[count / 4];
                Buffer.BlockCopy(buffer, 0, output, 0, output.Length * 4);
                return output;
            }
            case 16:
            {
                var output = new float[count / 2];
                for (var i = 0; i < output.Length; i++) output[i] = BitConverter.ToInt16(buffer, i * 2) / 32768f;
                return output;
            }
            case 24:
            {
                var output = new float[count / 3];
                for (var i = 0; i < output.Length; i++)
                    output[i] = ((buffer[i * 3] << 8 | buffer[i * 3 + 1] << 16 | buffer[i * 3 + 2] << 24) >> 8) / 8388608f;
                return output;
            }
            case 32:
            {
                var output = new float[count / 4];
                for (var i = 0; i < output.Length; i++) output[i] = BitConverter.ToInt32(buffer, i * 4) / 2147483648f;
                return output;
            }
            default:
                return Array.Empty<float>();
        }
    }
}
