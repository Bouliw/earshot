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
    readonly object gate = new();
    readonly Func<bool> isRecording;
    readonly Func<AppSettings> settings;
    readonly CancellationTokenSource stop = new();
    bool running;

    /// <summary>Raised on a worker thread: (folder, progress).</summary>
    public event Action<string, JobProgress>? Progress;
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

    public void Enqueue(string folder)
    {
        lock (gate)
        {
            if (Current == folder || waiting.Contains(folder)) return;
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
            lock (gate)
            {
                if (waiting.Count == 0 || stop.IsCancellationRequested) { running = false; Current = null; return; }
                folder = waiting.Dequeue();
                Current = folder;
            }
            try
            {
                var record = await TranscriptionJob.RunAsync(folder, settings(), new AacEncoder(), WhileRecording, p =>
                {
                    CurrentProgress = p;
                    Progress?.Invoke(folder, p);
                }, stop.Token);
                Finished?.Invoke(folder, record, null);
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
