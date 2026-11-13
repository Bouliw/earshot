using Earshot.Core;

namespace Earshot.Engines;

/// <summary>Runs the whole after-the-call pipeline on WAV files, without a call: the session folder, the models, voices,
/// Whisper and Transcript.txt. Used by the command-line check and by "Earshot.exe --check" in CI, which proves the
/// native libraries shipped in the zip load on that machine.</summary>
public static class SelfCheck
{
    public const string Usage =
        "--check <pc-sound.wav> [--mic <mic.wav>] [--model large-v3-turbo|large-v3-turbo-q5_0|small|base] " +
        "[--models <folder>] [--language auto|en|fr] [--no-voices] [--expect <word>] [--out <file>]";

    public static async Task<int> RunAsync(string[] args, TextWriter log)
    {
        string? Option(string name)
        {
            var i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        var first = Array.IndexOf(args, "--check");
        var appWav = first >= 0 && first + 1 < args.Length ? args[first + 1] : null;
        if (appWav is null || !File.Exists(appWav))
        {
            log.WriteLine("Usage: " + Usage);
            return 2;
        }
        var settings = new AppSettings
        {
            Model = Option("--model") ?? "base",
            Language = Option("--language") ?? "auto",
            SeparateVoices = !args.Contains("--no-voices"),
        };
        var root = Path.Combine(Path.GetTempPath(), "earshot-check-" + Guid.NewGuid().ToString("N")[..8]);
        var folder = SessionStore.NewFolder(root, "Check", DateTime.Now);
        Directory.CreateDirectory(folder);
        var record = new SessionRecord { Title = "Check", StartedAt = DateTime.UtcNow, Status = SessionRecord.Pending };
        SessionStore.Write(record, folder);
        using (var track = new RawTrack(Path.Combine(folder, SessionStore.AppTrackName))) track.Append(WavFile.Read16kMono(appWav));
        if (Option("--mic") is { } micWav)
            using (var track = new RawTrack(Path.Combine(folder, SessionStore.MicTrackName))) track.Append(WavFile.Read16kMono(micWav));

        log.WriteLine($"Runtime: {Environment.OSVersion} {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}");
        var started = DateTime.UtcNow;
        var lastStage = (JobStage)(-1);
        try
        {
            var result = await TranscriptionJob.RunAsync(folder, settings, new WaveEncoder(), () => Task.CompletedTask, p =>
            {
                if (p.Stage != lastStage) { lastStage = p.Stage; log.WriteLine($"{p.Stage} {p.Detail}"); }
            }, default, Option("--models"));
            var text = File.ReadAllText(Path.Combine(folder, SessionStore.TranscriptName));
            log.WriteLine($"Took {(DateTime.UtcNow - started).TotalSeconds:0.0} s for {result.Duration:0.0} s of audio, {result.Segments.Count} lines, speakers: {string.Join(", ", result.Speakers)}");
            log.WriteLine(text);
            if (result.Segments.Count == 0) { log.WriteLine("FAIL: empty transcript"); return 1; }
            if (Option("--expect") is { } word && !text.Contains(word, StringComparison.OrdinalIgnoreCase))
            {
                log.WriteLine($"FAIL: \"{word}\" not in the transcript");
                return 1;
            }
            log.WriteLine("OK");
            return 0;
        }
        catch (Exception error)
        {
            log.WriteLine("FAIL: " + error);
            return 1;
        }
        finally
        {
            try { Directory.Delete(root, true); } catch (Exception) { }
        }
    }
}
