using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Earshot.Core;
using Earshot.Desktop.Audio;
using Earshot.Engines;

namespace Earshot.Desktop;

/// <summary>A session in the list on the left.</summary>
public sealed class SessionItem
{
    public required SessionRecord Record { get; init; }
    public string Title => Record.Title;
    public string Subtitle => When(Record);

    /// <summary>The date in the language of Windows ("13 novembre 2026 · 09:00 · 21 min"), then the length.</summary>
    public static string When(SessionRecord r)
    {
        var local = DateTime.SpecifyKind(r.StartedAt, DateTimeKind.Utc).ToLocalTime();
        var culture = CultureInfo.CurrentCulture;
        var date = local.ToString(culture.DateTimeFormat.LongDatePattern.Replace("dddd", "").Trim(' ', ',', '.'), culture);
        return $"{date} · {local.ToString("t", culture)}" + (r.Duration > 0 ? " · " + L.Minutes(r.Duration) : "");
    }
    public string Status { get; init; } = "";
    public Visibility StatusVisibility => Status.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
}

/// <summary>One speaker's turn in the transcript view.</summary>
public sealed class TurnItem
{
    public string? Speaker { get; init; }
    public string SpeakerText => Speaker ?? "—";
    public required string Time { get; init; }
    public required string Text { get; init; }
    public required Brush Brush { get; init; }
    public string RenameTip => L.RenameSpeaker;
}

public partial class MainWindow : Window
{
    readonly App app;
    readonly DispatcherTimer ticker;
    SessionRecord? shown;
    bool loadingMicrophones;

    /// <summary>Set when the app quits; closing the window otherwise only hides it.</summary>
    public bool AllowClose { get; set; }

    public MainWindow(App app)
    {
        this.app = app;
        InitializeComponent();
        // Fits small screens (and virtual machines) whole.
        var area = SystemParameters.WorkArea;
        Width = Math.Min(Width, area.Width - 24);
        Height = Math.Min(Height, area.Height - 24);
        MinWidth = Math.Min(MinWidth, Width);
        MinHeight = Math.Min(MinHeight, Height);
        ApplyTexts();
        LoadMicrophones();
        RefreshSessions();
        UpdateRecordingState();
        ticker = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        ticker.Tick += (_, _) => Tick();
        ticker.Start();
    }

    void ApplyTexts()
    {
        SettingsButton.ToolTip = L.Settings;
        MicLabel.Text = L.Microphone;
        PcLabel.Text = L.PcSound;
        MicMeterLabel.Text = L.Microphone;
        RecordHint.Text = L.RecordHint;
        SessionsLabel.Text = L.Sessions;
        FolderButton.Content = L.OpenFolder;
        RetryButton.Content = L.TranscribeAgain;
        SummaryHeading.Text = L.SummaryTitle;
        RenameHint.Text = L.ClickToRename;
        TitleBox.ToolTip = L.TitlePlaceholder;
        TitleHint.Text = L.DefaultTitle(DateTime.Now);
    }

    // MARK: Recording

    public void LoadMicrophones()
    {
        loadingMicrophones = true;
        var items = new List<MicrophoneDevice> { new("", L.DefaultMicrophone) };
        items.AddRange(Recorder.Microphones());
        items.Add(new MicrophoneDevice("none", L.NoMicrophone));
        MicBox.ItemsSource = items;
        MicBox.SelectedItem = items.FirstOrDefault(m => m.Id == app.Settings.Microphone) ?? items[0];
        loadingMicrophones = false;
    }

    void OnMicChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loadingMicrophones || MicBox.SelectedItem is not MicrophoneDevice mic) return;
        app.Settings.Microphone = mic.Id;
        app.SaveSettings();
    }

    void OnTitleChanged(object sender, TextChangedEventArgs e) =>
        TitleHint.Visibility = TitleBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    void OnRecord(object sender, RoutedEventArgs e)
    {
        if (app.Recorder.IsRecording) app.StopRecording();
        else if (app.StartRecording(TitleBox.Text)) TitleBox.Text = "";
    }

    public void UpdateRecordingState()
    {
        var recording = app.Recorder.IsRecording;
        RecordText.Text = recording ? L.Stop : L.Record;
        RecordGlyph.Text = recording ? "" : "";
        LivePanel.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        RecordHint.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        TitleBox.IsEnabled = !recording;
        MicBox.IsEnabled = !recording;
        MicMeter.Visibility = MicMeterLabel.Visibility = recording && app.Recorder.HasMicrophone ? Visibility.Visible : Visibility.Collapsed;
        Title = recording ? $"Earshot · {L.Recording}" : "Earshot";
    }

    void Tick()
    {
        if (!app.Recorder.IsRecording)
        {
            if (DateTime.Now.Second == 0) TitleHint.Text = L.DefaultTitle(DateTime.Now);
            return;
        }
        var t = app.Recorder.Elapsed;
        ElapsedText.Text = t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"mm\:ss");
        PcMeter.Value = Meter(app.Recorder.PcLevel);
        MicMeter.Value = Meter(app.Recorder.MicLevel);
    }

    /// <summary>RMS to a meter position that moves for quiet voices too.</summary>
    static double Meter(float rms) => Math.Clamp(Math.Sqrt(rms) * 2.2, 0, 1);

    // MARK: Sessions

    public void RefreshSessions(string? select = null)
    {
        var folder = select ?? shown?.Folder;
        var items = SessionStore.LoadAll(app.Settings.EffectiveSessionsFolder)
            .Select(r => new SessionItem { Record = r, Status = StatusOf(r) }).ToList();
        SessionList.ItemsSource = items;
        EmptyText.Text = items.Count == 0 ? L.NoSessions : L.NoSelection;
        // Nothing chosen yet: the newest session is shown.
        var match = folder == null ? items.FirstOrDefault() : items.FirstOrDefault(i => SameFolder(i.Record.Folder, folder));
        if (match != null) SessionList.SelectedItem = match;
        else Show(null);
    }

    static bool SameFolder(string? a, string? b) =>
        a != null && b != null && string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);

    string StatusOf(SessionRecord r)
    {
        if (app.RecordingFolder != null && SameFolder(r.Folder, app.RecordingFolder)) return L.Recording;
        if (app.Queue.Current != null && SameFolder(r.Folder, app.Queue.Current) && app.Queue.CurrentProgress is { Stage: JobStage.Summarizing } s)
            return Describe(s);
        if (r.Status == SessionRecord.Failed) return L.Failed(r.Failure ?? "");
        if (r.Status != SessionRecord.Pending) return "";
        if (app.Queue.Current != null && SameFolder(r.Folder, app.Queue.Current) && app.Queue.CurrentProgress is { } p) return Describe(p);
        return L.Waiting;
    }

    void OnSessionSelected(object sender, SelectionChangedEventArgs e) => Show((SessionList.SelectedItem as SessionItem)?.Record);

    void Show(SessionRecord? record)
    {
        shown = record;
        EmptyText.Visibility = record == null ? Visibility.Visible : Visibility.Collapsed;
        DetailPanel.Visibility = record == null ? Visibility.Collapsed : Visibility.Visible;
        if (record == null) return;
        DetailTitle.Text = record.Title;
        DetailSubtitle.Text = SessionItem.When(record);
        var status = StatusOf(record);
        if (status.Length == 0 && record.Segments.Count == 0) status = L.NothingSaid;
        DetailStatus.Text = status;
        DetailStatus.Visibility = status.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        var canRetry = record.Status == SessionRecord.Failed && record.Folder != null && !app.Queue.Contains(record.Folder)
            && File.Exists(Path.Combine(record.Folder, SessionStore.AppTrackName));
        RetryButton.Visibility = canRetry ? Visibility.Visible : Visibility.Collapsed;
        RenameHint.Visibility = record.Segments.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSummary(Summary.Load(record.Folder));
        var busy = record.Folder != null && app.Queue.Contains(record.Folder);
        SummarizeButton.Content = Summary.Load(record.Folder) == null ? L.Summarize : L.SummarizeAgain;
        SummarizeButton.Visibility = record.Segments.Count > 0 && record.Status == null && !busy ? Visibility.Visible : Visibility.Collapsed;
        var local = DateTime.SpecifyKind(record.StartedAt, DateTimeKind.Utc).ToLocalTime();
        TurnList.ItemsSource = Turn.Group(record.Segments).Select(t => new TurnItem
        {
            Speaker = t.Speaker,
            Time = local.AddSeconds(t.Start).ToString("T", CultureInfo.CurrentCulture),
            Text = t.Text,
            Brush = SpeakerBrush(t.Speaker),
        }).ToList();
    }

    /// <summary>Summary.txt above the transcript, without its first line (the title and date are shown already), headings in bold.</summary>
    void ShowSummary(string? text)
    {
        SummaryText.Inlines.Clear();
        SummaryPanel.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
        if (text == null) return;
        var lines = text.Replace("\r", "").Split('\n').Skip(1).SkipWhile(l => l.Length == 0).ToList();
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            if (Summary.AllHeadings.Contains(line)) SummaryText.Inlines.Add(new System.Windows.Documents.Run(line) { FontWeight = FontWeights.SemiBold });
            else SummaryText.Inlines.Add(new System.Windows.Documents.Run(line.StartsWith("- ") ? "•  " + line[2..] : line));
            if (i < lines.Count - 1) SummaryText.Inlines.Add(new System.Windows.Documents.LineBreak());
        }
    }

    void OnSummarize(object sender, RoutedEventArgs e)
    {
        if (shown?.Folder is not { } folder) return;
        app.Queue.Enqueue(folder, summaryOnly: true);
        SummarizeButton.Visibility = Visibility.Collapsed;
    }

    void OnTurnWheel(object sender, MouseWheelEventArgs e)
    {
        // The transcript's text boxes would keep the wheel for themselves.
        TurnScroller.ScrollToVerticalOffset(TurnScroller.VerticalOffset - e.Delta / 2.0);
        e.Handled = true;
    }

    void OnRenameSpeaker(object sender, RoutedEventArgs e)
    {
        if (shown?.Folder is not { } folder || (sender as FrameworkElement)?.Tag is not TurnItem turn) return;
        var dialog = new RenameWindow(turn.Speaker ?? "") { Owner = this };
        if (dialog.ShowDialog() != true || dialog.NewName.Length == 0 || dialog.NewName == turn.Speaker) return;
        var record = SessionStore.Load(folder) ?? shown;
        record.Rename(turn.Speaker, dialog.NewName);
        SessionStore.Write(record, folder);
        RefreshSessions(folder);
    }

    void OnRetry(object sender, RoutedEventArgs e)
    {
        if (shown?.Folder is not { } folder) return;
        var record = SessionStore.Load(folder);
        if (record == null) return;
        record.Status = SessionRecord.Pending;
        record.Failure = null;
        SessionStore.Write(record, folder);
        app.Queue.Enqueue(folder);
        RefreshSessions(folder);
    }

    void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        if (shown?.Folder is { } folder && Directory.Exists(folder))
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    void OnSettings(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(app.Settings) { Owner = this };
        if (dialog.ShowDialog() != true) return;
        app.SaveSettings();
        RefreshSessions();
    }

    // MARK: Transcription progress

    static string Describe(JobProgress p) => p.Stage switch
    {
        JobStage.Downloading => L.Downloading(p.Detail.Split(" · ")[0], p.Detail.Contains(" · ") ? p.Detail.Split(" · ")[1] : $"{p.Fraction:P0}"),
        JobStage.Voices => L.TellingVoicesApart,
        JobStage.Summarizing => L.Summarizing((int)Math.Round(p.Fraction * 100)),
        _ => L.Transcribing((int)Math.Round(p.Fraction * 100)),
    };

    public void OnJobProgress(string folder, JobProgress p)
    {
        JobPanel.Visibility = Visibility.Visible;
        JobTitle.Text = SessionStore.Load(folder)?.Title ?? Path.GetFileName(folder);
        JobText.Text = app.Recorder.IsRecording && p.Stage is JobStage.Transcribing or JobStage.Summarizing ? L.WaitingForRecording : Describe(p);
        JobBar.Value = p.Fraction;
        if (shown != null && SameFolder(shown.Folder, folder)) DetailStatus.Text = JobText.Text;
    }

    public void OnJobFinished(string folder)
    {
        if (!app.Queue.IsBusy) JobPanel.Visibility = Visibility.Collapsed;
        RefreshSessions();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!AllowClose)
        {
            e.Cancel = true;
            Hide();
            app.TellAboutTray();
        }
        base.OnClosing(e);
    }

    // MARK: Speaker colors, as on the Mac (same hash, so a name keeps its color).

    static readonly Brush[] Palette = new[]
    {
        "#1F6FEB", "#D9730D", "#D6336C", "#2F9E44", "#9C36B5", "#0C8599", "#4C6EF5", "#099268", "#E03131", "#1098AD",
    }.Select(c => (Brush)new BrushConverter().ConvertFromString(c)!).ToArray();

    static Brush SpeakerBrush(string? name)
    {
        if (name == null) return Brushes.Gray;
        uint h = 7;
        foreach (var rune in name.EnumerateRunes()) h = unchecked(h * 31 + (uint)rune.Value);
        return Palette[h % (uint)Palette.Length];
    }
}
