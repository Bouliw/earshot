using Earshot.Core;
using SherpaOnnx;
using Whisper.net;

namespace Earshot.Engines;

/// <summary>whisper.cpp through Whisper.net, on the CPU. Not thread-safe: one call at a time.</summary>
public sealed class WhisperEngine : ISpeechRecognizer, IDisposable
{
    readonly WhisperFactory factory;
    readonly WhisperProcessor processor;
    readonly object gate = new();

    public string ModelPath { get; }

    public WhisperEngine(string modelPath)
    {
        ModelPath = modelPath;
        factory = WhisperFactory.FromPath(modelPath);
        processor = factory.CreateBuilder()
            .WithLanguage("auto")
            .WithNoContext()   // a prompt from the previous piece caused repetitions on the Mac
            .WithThreads(Math.Clamp(Environment.ProcessorCount, 1, 8))
            .Build();
    }

    public (string Code, float Probability)? DetectLanguage(float[] samples)
    {
        lock (gate)
        {
            var (language, probability) = processor.DetectLanguageWithProbability(samples);
            return string.IsNullOrEmpty(language) ? null : (language!, probability);
        }
    }

    public IReadOnlyList<RecognizedLine> Transcribe(float[] samples, string language)
    {
        lock (gate)
        {
            processor.ChangeLanguage(language);
            var lines = new List<RecognizedLine>();
            foreach (var s in processor.ProcessAsync(samples).ToBlockingEnumerable())
                lines.Add(new RecognizedLine(s.Start.TotalSeconds, s.End.TotalSeconds, s.Text.Trim(), s.NoSpeechProbability));
            return lines;
        }
    }

    public void Dispose()
    {
        processor.Dispose();
        factory.Dispose();
    }

    /// <summary>Loading takes a few seconds, so the last model stays in memory between sessions.</summary>
    static WhisperEngine? cached;
    static readonly object cacheGate = new();

    public static WhisperEngine Cached(string modelPath)
    {
        lock (cacheGate)
        {
            if (cached?.ModelPath == modelPath) return cached;
            cached?.Dispose();
            cached = null;
            cached = new WhisperEngine(modelPath);
            return cached;
        }
    }
}

/// <summary>Silero's voice activity model, run by sherpa-onnx: where someone is actually speaking.
/// Whisper writes stock lines over breathing, typing and room noise; the sound level cannot tell that noise from a
/// quiet voice, this model can, so Whisper only gets the stretches where a voice is heard.</summary>
public sealed class SherpaVoiceActivity : IVoiceActivity
{
    readonly string modelPath;

    public SherpaVoiceActivity(string modelPath) => this.modelPath = modelPath;

    public IReadOnlyList<(double Start, double End)> Speech(float[] samples, double maxLength)
    {
        var config = new VadModelConfig();
        config.SileroVad.Model = modelPath;
        config.SileroVad.Threshold = 0.5f;
        config.SileroVad.MinSilenceDuration = 0.5f;
        config.SileroVad.MinSpeechDuration = 0.25f;  // a click or a breath is shorter than a word
        config.SileroVad.MaxSpeechDuration = (float)maxLength;
        config.SileroVad.WindowSize = 512;
        config.SampleRate = Chunker.Rate;
        config.NumThreads = 1;
        config.Debug = 0;
        using var vad = new VoiceActivityDetector(config, (float)maxLength + 30);
        var output = new List<(double, double)>();
        void Drain()
        {
            while (!vad.IsEmpty())
            {
                var segment = vad.Front();
                var start = segment.Start / (double)Chunker.Rate;
                output.Add((start, start + segment.Samples.Length / (double)Chunker.Rate));
                vad.Pop();
            }
        }
        const int window = 512;
        for (var i = 0; i < samples.Length; i += window)
        {
            var n = Math.Min(window, samples.Length - i);
            var chunk = new float[window];
            Array.Copy(samples, i, chunk, 0, n);
            vad.AcceptWaveform(chunk);
            Drain();
        }
        vad.Flush();
        Drain();
        return output.OrderBy(s => s.Item1).ToList();
    }
}

/// <summary>Tells voices apart with sherpa-onnx: pyannote's segmentation, speaker embeddings, then clustering.</summary>
public sealed class SherpaVoiceSeparator : IVoiceSeparator
{
    readonly string segmentationModel;
    readonly string embeddingModel;

    public SherpaVoiceSeparator(string segmentationModel, string embeddingModel)
    {
        this.segmentationModel = segmentationModel;
        this.embeddingModel = embeddingModel;
    }

    public IReadOnlyList<VoiceTurn> Turns(float[] samples, Action<double> progress)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = segmentationModel;
        config.Segmentation.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
        config.Embedding.Model = embeddingModel;
        config.Embedding.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
        config.Clustering.NumClusters = -1;   // the number of voices is not known in advance
        // Higher merges more. On a recorded two-person call, 0.5 split the two voices into five; 0.8 found the two.
        config.Clustering.Threshold = 0.8f;
        config.MinDurationOn = 0.3f;
        config.MinDurationOff = 0.5f;
        using var diarizer = new OfflineSpeakerDiarization(config);
        OfflineSpeakerDiarizationProgressCallback callback = (done, total, _) =>
        {
            if (total > 0) progress(done / (double)total);
            return 0;
        };
        var segments = diarizer.ProcessWithCallback(samples, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return segments
            .Select(s => new VoiceTurn(s.Start, s.End, $"S{s.Speaker}"))
            .Where(t => t.End > t.Start)
            .OrderBy(t => t.Start)
            .ToList();
    }
}
