using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Earshot.Core;
using Earshot.Desktop.Audio;
using Earshot.Engines;

namespace Earshot.Desktop;

/// <summary>Transcribes finished sessions one at a time, in the background. A job holds off while a call is being
/// recorded, so the PC stays responsive during the call.</summary>
public sealed class TranscriptionQueue
{
    readonly Queue<string> waiting = new();
    readonly HashSet<string> summaryOnly = new();
    readonly object gate = new();
    readonly Func<bool> isRecording;
    readonly Func<AppSettings> settings;
    readonly CancellationTokenSource stop = new();
    bool running;

    /// <summary>Raised on a worker thread: (folder, progress).</summary>
    public event Action<string, JobProgress>? Progress;
    /// <summary>Raised on a worker thread once a transcript is saved, before its summary is written.</summary>
    public event Action<string, SessionRecord>? Transcribed;
    /// <summary>Raised on a worker thread: (folder, record or null, error or null).</summary>
    public event Action<string, SessionRecord?, Exception?>? Finished;

    public string? Current { get; private set; }
    public JobProgress? CurrentProgress { get; private set; }
    public bool IsBusy { get { lock (gate) return running; } }

    public TranscriptionQueue(Func<bool> isRecording, Func<AppSettings> settings)
    {
        this.isRecording = isRecording;
        this.settings = settings;
    }

    public bool Contains(string folder)
    {
        lock (gate) return Current == folder || waiting.Contains(folder);
    }

    /// <param name="folder">The session.</param>
    /// <param name="summaryOnly">Only write Summary.txt again, from the transcript it has.</param>
    public void Enqueue(string folder, bool summaryOnly = false)
    {
        lock (gate)
        {
            if (Current == folder || waiting.Contains(folder)) return;
            if (summaryOnly) this.summaryOnly.Add(folder);
            waiting.Enqueue(folder);
            if (running) return;
            running = true;
        }
        Task.Run(Work);
    }

    async Task Work()
    {
        while (true)
        {
            string folder;
            bool onlySummary;
            lock (gate)
            {
                if (waiting.Count == 0 || stop.IsCancellationRequested) { running = false; Current = null; return; }
                folder = waiting.Dequeue();
                onlySummary = summaryOnly.Remove(folder);
                Current = folder;
            }
            void Report(JobProgress p)
            {
                CurrentProgress = p;
                Progress?.Invoke(folder, p);
            }
            try
            {
                if (onlySummary)
                {
                    await TranscriptionJob.SummarizeAsync(folder, settings(), WhileRecording, Report, stop.Token);
                    Finished?.Invoke(folder, SessionStore.Load(folder), null);
                }
                else
                {
                    var record = await TranscriptionJob.RunAsync(folder, settings(), new AacEncoder(), WhileRecording, Report, stop.Token,
                        transcribed: r => Transcribed?.Invoke(folder, r));
                    Finished?.Invoke(folder, record, null);
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception error)
            {
                Finished?.Invoke(folder, SessionStore.Load(folder), error);
            }
            finally { CurrentProgress = null; }
        }
    }

    async Task WhileRecording()
    {
        while (isRecording() && !stop.IsCancellationRequested) await Task.Delay(1000);
    }

    public void Cancel() => stop.Cancel();
}
