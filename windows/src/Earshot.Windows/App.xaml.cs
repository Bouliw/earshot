using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Earshot.Core;
using Earshot.Desktop.Audio;
using Earshot.Engines;

namespace Earshot.Desktop;

public partial class App : Application
{
    const string InstanceName = "Local\\Earshot-Windows";
    const string ShowEventName = "Local\\Earshot-Windows-Show";

    Mutex? instance;
    EventWaitHandle? showSignal;
    MainWindow? window;
    Tray? tray;
    SessionRecord? recording;
    bool quitting;

    public AppSettings Settings { get; private set; } = new();
    public Recorder Recorder { get; } = new();
    public TranscriptionQueue Queue { get; private set; } = null!;
    /// <summary>The folder of the session being recorded, if any.</summary>
    public string? RecordingFolder => recording?.Folder;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--check") || e.Args.Contains("--summarize"))
        {
            RunCheck(e.Args);
            return;
        }

        // One Earshot at a time: a second launch brings the first one's window up.
        instance = new Mutex(true, InstanceName, out var first);
        if (!first)
        {
            try { EventWaitHandle.OpenExisting(ShowEventName).Set(); } catch (Exception) { }
            Shutdown();
            return;
        }
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        new Thread(() =>
        {
            while (showSignal.WaitOne()) Dispatcher.BeginInvoke(ShowWindow);
        }) { IsBackground = true }.Start();

        DispatcherUnhandledException += OnUnhandled;
        Settings = AppSettings.Load();
        Queue = new TranscriptionQueue(() => Recorder.IsRecording, () => Settings);
        Queue.Progress += (folder, p) => Dispatcher.BeginInvoke(() => window?.OnJobProgress(folder, p));
        Queue.Transcribed += (folder, _) => Dispatcher.BeginInvoke(() => window?.RefreshSessions());
        Queue.Finished += (folder, record, error) => Dispatcher.BeginInvoke(() =>
        {
            window?.OnJobFinished(folder);
            if (record != null && error == null && window?.IsVisible != true) tray?.Notify(L.Done(record.Title));
            if (error != null && window?.IsVisible != true) tray?.Notify(L.Failed(error.Message));
        });

        window = new MainWindow(this);
        tray = new Tray(this);
        window.Show();
        ResumePending();
    }

    /// <summary>Sessions left waiting (Earshot quit or the PC stopped before their transcript): written now.</summary>
    void ResumePending()
    {
        var pending = SessionStore.LoadAll(Settings.EffectiveSessionsFolder)
            .Where(r => r.Status == SessionRecord.Pending && r.Folder != null
                        && (File.Exists(Path.Combine(r.Folder, SessionStore.AppTrackName)) || File.Exists(Path.Combine(r.Folder, SessionStore.MicTrackName))))
            .OrderBy(r => r.StartedAt).ToList();
        foreach (var r in pending)
        {
            var folder = r.Folder!;
            Task.Run(() =>
            {
                try { TranscriptionJob.WriteAudio(folder, new AacEncoder()); } catch (Exception) { }
            }).ContinueWith(_ => Queue.Enqueue(folder));
        }
    }

    public void SaveSettings()
    {
        try { Settings.Save(); } catch (Exception) { /* read-only profile: the choice lasts for this run */ }
    }

    // MARK: Recording

    /// <summary>Starts a session titled <paramref name="title"/> (or "Call &lt;date&gt;"). False when it could not start.</summary>
    public bool StartRecording(string title)
    {
        if (Recorder.IsRecording) return false;
        var now = DateTime.Now;
        title = string.IsNullOrWhiteSpace(title) ? L.DefaultTitle(now) : title.Trim();
        var folder = SessionStore.NewFolder(Settings.EffectiveSessionsFolder, title, now);
        var record = new SessionRecord { Title = title, StartedAt = DateTime.UtcNow, Status = SessionRecord.Pending, Folder = folder };
        try
        {
            SessionStore.Write(record, folder);
            Recorder.Start(folder, Settings.Microphone);
        }
        catch (Exception error)
        {
            try { Directory.Delete(folder, true); } catch (Exception) { }
            MessageBox.Show(window!, error.Message, "Earshot", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        recording = record;
        window?.UpdateRecordingState();
        tray?.Update(true);
        window?.RefreshSessions(folder);
        return true;
    }

    public void StopRecording(bool transcribe = true)
    {
        if (!Recorder.IsRecording || recording?.Folder is not { } folder) return;
        var record = recording;
        var duration = Recorder.Stop();
        recording = null;
        record.Duration = duration;
        SessionStore.Write(record, folder);
        window?.UpdateRecordingState();
        tray?.Update(false);
        window?.RefreshSessions(folder);
        if (!transcribe) return;
        Task.Run(() =>
        {
            try { TranscriptionJob.WriteAudio(folder, new AacEncoder()); } catch (Exception) { /* written by the job */ }
        }).ContinueWith(_ => Queue.Enqueue(folder));
    }

    public void ToggleRecording()
    {
        if (Recorder.IsRecording) StopRecording();
        else StartRecording("");
    }

    // MARK: Window and tray

    public void ShowWindow()
    {
        if (window == null) return;
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public void TellAboutTray()
    {
        if (Settings.ToldAboutTray) return;
        Settings.ToldAboutTray = true;
        SaveSettings();
        tray?.Notify(L.KeepsRunning);
    }

    public void Quit()
    {
        if (quitting) return;
        if (Recorder.IsRecording || Queue.IsBusy)
        {
            ShowWindow();
            var answer = MessageBox.Show(window!, L.QuitWhileBusy, "Earshot", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (answer != MessageBoxResult.OK) return;
        }
        quitting = true;
        StopRecording(transcribe: false);  // kept as pending: transcribed at the next launch
        Queue.Cancel();
        tray?.Dispose();
        if (window != null) { window.AllowClose = true; window.Close(); }
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Recorder.Dispose();
        tray?.Dispose();
        instance?.Dispose();
        base.OnExit(e);
    }

    void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            var log = Path.Combine(Path.GetDirectoryName(AppSettings.DefaultPath)!, "errors.log");
            File.AppendAllText(log, $"{DateTime.Now:O} {e.Exception}\n\n");
        }
        catch (Exception) { }
        MessageBox.Show(e.Exception.Message, "Earshot", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }

    // MARK: Command-line check

    /// <summary>Earshot.exe --check pc.wav [...] --out result.txt: the whole pipeline on a file, with the native libraries
    /// of this install. The exit code says whether it worked (0) or not.</summary>
    void RunCheck(string[] args)
    {
        var index = Array.IndexOf(args, "--out");
        var outPath = index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        int code;
        using (var writer = outPath != null ? new StreamWriter(outPath) { AutoFlush = true } : TextWriter.Null)
        {
            code = Task.Run(() => SelfCheck.RunAsync(args, writer)).GetAwaiter().GetResult();
        }
        Environment.Exit(code);
    }
}
