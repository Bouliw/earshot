using System.Text.Json;
using System.Text.RegularExpressions;
using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

public sealed class SessionTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "earshot-tests-" + Guid.NewGuid().ToString("N"));

    public SessionTests() => L.Use("en");
    public void Dispose() { try { Directory.Delete(root, true); } catch (DirectoryNotFoundException) { } }

    static SessionRecord Sample() => new()
    {
        Title = "Weekly sync",
        StartedAt = new DateTime(2026, 11, 13, 14, 5, 41, DateTimeKind.Utc),
        Duration = 42,
        Segments = new()
        {
            new Segment(0, 2, "Hello there.", "Speaker 1"),
            new Segment(2.5, 4, "How are you?", "Speaker 1"),
            new Segment(5, 7, "Fine, thanks.", "Me", true),
        },
    };

    [Fact]
    public void TranscriptMatchesTheMacFormat()
    {
        var text = SessionStore.Text(Sample());
        const string time = @"\d{1,2}:\d\d:\d\d\u202F(AM|PM)";
        var expected = new Regex(
            @"^Weekly sync — November 13, 2026 at \d{1,2}:\d\d\u202F(AM|PM)\n" +
            $@"\n\[{time}\] Speaker 1\nHello there\. How are you\?\n" +
            $@"\n\[{time}\] Me\nFine, thanks\.\n$");
        Assert.Matches(expected, text);
    }

    [Fact]
    public void TurnsJoinTheSameSpeakerWithinTwoMinutes()
    {
        var turns = Turn.Group(new[]
        {
            new Segment(0, 1, "a", "A"), new Segment(1, 2, "b", "A"), new Segment(130, 131, "c", "A"), new Segment(132, 133, "d", "B"),
        });
        Assert.Equal(new[] { "a b", "c", "d" }, turns.Select(t => t.Text));
    }

    [Fact]
    public void RecordKeepsTheMacSchema()
    {
        var json = JsonSerializer.Serialize(Sample(), Json.Options);
        using var doc = JsonDocument.Parse(json);
        var keys = doc.RootElement.EnumerateObject().Select(p => p.Name).ToList();
        Assert.Equal(new[] { "appName", "bundleID", "duration", "id", "segments", "startedAt", "title" }, keys);
        Assert.Equal("2026-11-13T14:05:41Z", doc.RootElement.GetProperty("startedAt").GetString());
        var first = doc.RootElement.GetProperty("segments")[0];
        Assert.Equal(new[] { "end", "id", "speaker", "start", "text" }, first.EnumerateObject().Select(p => p.Name));
        Assert.True(doc.RootElement.GetProperty("segments")[2].GetProperty("mic").GetBoolean());
        Assert.Matches("^[0-9A-F-]{36}$", first.GetProperty("id").GetString()!);
    }

    [Fact]
    public void ReadsARecordWrittenOnTheMac()
    {
        const string mac = """
        {
          "appName" : "Safari",
          "bundleID" : "com.apple.Safari",
          "duration" : 1402.97,
          "id" : "5959E231-29B0-42C7-9B71-06DC626D1EDD",
          "names" : [ { "name" : "Ada Lovelace", "time" : 3.5 } ],
          "segments" : [
            { "end" : 3.09, "id" : "14FEE077-262A-4512-8344-081FAA813B63", "speaker" : "Speaker 1", "start" : 0, "text" : "Ça fait un an\/deux." },
            { "end" : 5, "id" : "24FEE077-262A-4512-8344-081FAA813B63", "mic" : true, "speaker" : "Me", "start" : 4, "text" : "Oui." }
          ],
          "startedAt" : "2026-11-10T14:05:41Z",
          "status" : "pending",
          "title" : "Appel \/ test"
        }
        """;
        var folder = Path.Combine(root, "mac");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, SessionStore.RecordName), mac);
        var record = SessionStore.Load(folder)!;
        Assert.Equal("Appel / test", record.Title);
        Assert.Equal("Ça fait un an/deux.", record.Segments[0].Text);
        Assert.True(record.Segments[1].Mic);
        Assert.Equal(SessionRecord.Pending, record.Status);
        Assert.Equal("Ada Lovelace", record.Names![0].Name);
        Assert.Equal(new DateTime(2026, 11, 10, 14, 5, 41, DateTimeKind.Utc), record.StartedAt);
    }

    [Fact]
    public void WritesBothFilesAndLoadsThemBack()
    {
        var folder = SessionStore.NewFolder(root, "Weekly sync", new DateTime(2026, 11, 13, 15, 0, 0));
        SessionStore.Write(Sample(), folder);
        Assert.True(File.Exists(Path.Combine(folder, SessionStore.TranscriptName)));
        var all = SessionStore.LoadAll(root);
        Assert.Single(all);
        Assert.Equal("Weekly sync", all[0].Group);
        Assert.Equal(3, all[0].Segments.Count);
        Assert.False(File.Exists(Path.Combine(folder, SessionStore.RecordName + ".tmp")));
    }

    [Fact]
    public void FoldersAreNamedAfterTheTitleThenTheDay()
    {
        var day = new DateTime(2026, 11, 13, 9, 0, 0);
        var first = SessionStore.NewFolder(root, "Q&A: <budget>?", day);
        Assert.Equal(Path.Combine(root, "Q&A- -budget--", "2026-11-13"), first);
        Directory.CreateDirectory(first);
        Assert.Equal(Path.Combine(root, "Q&A- -budget--", "2026-11-13 2"), SessionStore.NewFolder(root, "Q&A: <budget>?", day));
    }

    [Theory]
    [InlineData("Call.", "Call")]
    [InlineData("  ", "Call")]
    [InlineData("CON", "CON-")]
    [InlineData("a/b\\c", "a-b-c")]
    public void FolderNamesAreSafeOnWindows(string title, string expected) => Assert.Equal(expected, SessionStore.SafeName(title));

    [Fact]
    public void RenamingMergesSpeakers()
    {
        var record = Sample();
        record.Segments.Add(new Segment(8, 9, "Bye.", "Speaker 2"));
        record.Rename("Speaker 2", "Speaker 1");
        Assert.Equal(new[] { "Speaker 1", "Me" }, record.Speakers);
        record.Rename("Speaker 1", "  ");
        Assert.Equal(new[] { "Speaker 1", "Me" }, record.Speakers);
        record.Rename("Speaker 1", "Ada");
        Assert.Equal(new[] { "Ada", "Me" }, record.Speakers);
    }

    [Fact]
    public void SettingsSurviveARestart()
    {
        var path = Path.Combine(root, "settings.json");
        var settings = new AppSettings { Model = "small", Language = "fr", UserName = "Ada", SeparateVoices = false, Microphone = "none" };
        settings.Save(path);
        var loaded = AppSettings.Load(path);
        Assert.Equal(("small", "fr", "Ada", false, "none"), (loaded.Model, loaded.Language, loaded.UserName, loaded.SeparateVoices, loaded.Microphone));
        Assert.Equal("Me", new AppSettings().EffectiveUserName);
        File.WriteAllText(path, "{ broken");
        Assert.Equal(ModelCatalog.DefaultWhisper, AppSettings.Load(path).Model);
    }

    [Fact]
    public void ClockReadsLikeTheMac()
    {
        Assert.Equal("1:15", Clock.Format(75));
        Assert.Equal("1:02:05", Clock.Format(3725));
        Assert.Equal("1 h 30 min", L.Minutes(5400));
    }
}
