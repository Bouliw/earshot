using Earshot.Core;

namespace Earshot.Engines;

/// <summary>Writes the session's audio file from its two raw tracks. The Windows app encodes AAC (Audio.m4a) and falls
/// back on WAV when the encoder is missing.</summary>
public interface IAudioEncoder
{
    /// <summary>Writes the audio into <paramref name="folder"/> and returns the file name used.</summary>
    string Write(float[] samples16kMono, string folder);
}

public sealed class WaveEncoder : IAudioEncoder
{
    public string Write(float[] samples, string folder)
    {
        WavFile.Write16(Path.Combine(folder, SessionStore.WaveAudioName), samples);
        return SessionStore.WaveAudioName;
    }
}

/// <summary>Where a job stands, for the window and the notification area.</summary>
public sealed record JobProgress(JobStage Stage, double Fraction, string Detail = "");

public enum JobStage { Downloading, Voices, Transcribing, Summarizing, Done }

/// <summary>Everything that happens to a session once the recording stops: the audio file, the models, the transcript,
/// then the raw tracks are dropped. A failure leaves the tracks in place and marks the session "failed".</summary>
public static class TranscriptionJob
{
    public static async Task<SessionRecord> RunAsync(string folder, AppSettings settings, IAudioEncoder encoder,
        Func<Task> pause, Action<JobProgress> report, CancellationToken cancel = default, string? modelsFolder = null,
        Action<SessionRecord>? transcribed = null)
    {
        var record = SessionStore.Load(folder) ?? throw new FileNotFoundException("Missing session file", Path.Combine(folder, SessionStore.RecordName));
        var appPath = Path.Combine(folder, SessionStore.AppTrackName);
        var micPath = Path.Combine(folder, SessionStore.MicTrackName);
        try
        {
            var app = RawTrack.Read(appPath);
            var mic = RawTrack.Read(micPath);
            if (app.Length == 0 && mic.Length == 0) throw new InvalidOperationException("The audio of this session is missing.");
            record.Duration = Math.Max(app.Length, mic.Length) / (double)Chunker.Rate;
            if (SessionStore.AudioFile(folder) is null) WriteAudio(app, mic, folder, encoder);

            string Download(ModelFile model) => model.Label;
            var whisperModel = ModelCatalog.WhisperModel(settings.Model);
            var whisperPath = await ModelDownloader.EnsureAsync(whisperModel,
                (d, t) => report(new JobProgress(JobStage.Downloading, t > 0 ? d / (double)t : 0, Download(whisperModel) + " · " + ModelDownloader.Bytes(d, t))), cancel, modelsFolder);

            IVoiceActivity? vad = null;
            try
            {
                vad = new SherpaVoiceActivity(await ModelDownloader.EnsureAsync(ModelCatalog.VoiceActivity,
                    (d, t) => report(new JobProgress(JobStage.Downloading, t > 0 ? d / (double)t : 0, ModelCatalog.VoiceActivity.Label)), cancel, modelsFolder));
            }
            catch (Exception) when (!cancel.IsCancellationRequested) { /* the sound level stands in */ }

            IVoiceSeparator? separator = null;
            if (settings.SeparateVoices && app.Length > 0)
            {
                try
                {
                    var segmentation = await ModelDownloader.EnsureAsync(ModelCatalog.Segmentation,
                        (d, t) => report(new JobProgress(JobStage.Downloading, t > 0 ? d / (double)t : 0, ModelCatalog.Segmentation.Label)), cancel, modelsFolder);
                    var embedding = await ModelDownloader.EnsureAsync(ModelCatalog.Embedding,
                        (d, t) => report(new JobProgress(JobStage.Downloading, t > 0 ? d / (double)t : 0, ModelCatalog.Embedding.Label)), cancel, modelsFolder);
                    separator = new SherpaVoiceSeparator(segmentation, embedding);
                }
                catch (Exception) when (!cancel.IsCancellationRequested) { /* one speaker on the other side */ }
            }

            var whisper = await Task.Run(() => WhisperEngine.Cached(whisperPath), cancel);
            var batch = new BatchTranscriber(whisper, vad, separator);
            var input = new BatchTranscriber.Input
            {
                Samples = app,
                Mic = mic.Length > 0 ? mic : null,
                Marks = record.Names ?? new List<NameMark>(),
                Language = settings.Language,
                SeparateVoices = settings.SeparateVoices,
                UserName = settings.EffectiveUserName,
                Pause = pause,
            };
            var segments = await Task.Run(() => batch.RunAsync(input,
                p => report(new JobProgress(p < 0.1 && separator != null ? JobStage.Voices : JobStage.Transcribing, p)), cancel), cancel);

            record.Segments = segments;
            record.Status = null;
            record.Failure = null;
            SessionStore.Write(record, folder);
            TryDelete(appPath);
            TryDelete(micPath);
            transcribed?.Invoke(record);
            if (settings.Summarize) await SummarizeAsync(folder, settings, pause, report, cancel, modelsFolder);
            report(new JobProgress(JobStage.Done, 1));
            return record;
        }
        catch (OperationCanceledException)
        {
            throw;  // still pending: picked up again at the next launch
        }
        catch (Exception error)
        {
            record.Status = SessionRecord.Failed;
            record.Failure = error.Message;
            SessionStore.Write(record, folder);
            throw;
        }
    }

    /// <summary>Summary.txt for a session that has its transcript, with the summary model chosen in Settings. A failure
    /// leaves the transcript as it is (and an older summary in place): the summary is a bonus. Returns whether one was written.</summary>
    public static async Task<bool> SummarizeAsync(string folder, AppSettings settings, Func<Task> pause, Action<JobProgress> report,
        CancellationToken cancel = default, string? modelsFolder = null)
    {
        var record = SessionStore.Load(folder);
        if (record == null || Summary.WordCount(record.Segments) < Summary.MinimumWords) return false;
        try
        {
            var model = ModelCatalog.SummaryModel(settings.SummaryModel);
            var path = await ModelDownloader.EnsureAsync(model,
                (d, t) => report(new JobProgress(JobStage.Downloading, t > 0 ? d / (double)t : 0, model.Label + " · " + ModelDownloader.Bytes(d, t))), cancel, modelsFolder);
            await pause();
            report(new JobProgress(JobStage.Summarizing, 0));
            var text = await Task.Run(() =>
            {
                var llm = LlamaSummaryModel.Cached(path);
                return Summary.Write(record, llm, LlamaSummaryModel.BlockWords, p => report(new JobProgress(JobStage.Summarizing, p)), cancel);
            }, cancel);
            if (text == null) return false;
            File.WriteAllText(Path.Combine(folder, Summary.FileName), text, new System.Text.UTF8Encoding(false));
            return true;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error)
        {
            LlamaSummaryModel.Log?.Invoke("summary: " + error);
            return false;
        }
        finally { LlamaSummaryModel.Release(); }  // several GB: freed until the next summary
    }

    /// <summary>Audio.m4a (or Audio.wav) from the session's two raw tracks, right when the recording stops, so the sound
    /// is there to play even while the transcript waits for its turn. The raw tracks stay for the transcript.</summary>
    public static void WriteAudio(string folder, IAudioEncoder encoder)
    {
        if (SessionStore.AudioFile(folder) != null) return;
        var app = RawTrack.Read(Path.Combine(folder, SessionStore.AppTrackName));
        var mic = RawTrack.Read(Path.Combine(folder, SessionStore.MicTrackName));
        if (app.Length > 0 || mic.Length > 0) WriteAudio(app, mic, folder, encoder);
    }

    static void WriteAudio(float[] app, float[] mic, string folder, IAudioEncoder encoder)
    {
        var mix = Resampler.Mix(app, mic);
        try { encoder.Write(mix, folder); }
        catch (Exception)
        {
            try { File.Delete(Path.Combine(folder, SessionStore.AudioName)); } catch (IOException) { }
            new WaveEncoder().Write(mix, folder);
        }
    }

    static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
