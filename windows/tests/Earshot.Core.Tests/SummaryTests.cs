using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

public sealed class SummaryTests
{
    static Segment S(string text, string? speaker = "Speaker 1") => new(0, 1, text, speaker);

    [Fact]
    public void TheSummaryIsWrittenInTheLanguageOfTheCall()
    {
        Assert.Equal("fr", Summary.Language(new[] { S("Bon, on part sur une sortie lundi et je relis les notes cet après-midi.") }));
        Assert.Equal("en", Summary.Language(new[] { S("So we ship on Monday and I will review the notes this afternoon.") }));
    }

    [Fact]
    public void BlocksKeepEachTurnUnderItsSpeakerAndStayUnderTheWordLimit()
    {
        var blocks = Summary.Blocks(new[] { S(string.Join(" ", Enumerable.Repeat("word", 25)), "Ada"), S("short reply", "Me") }, 10);
        Assert.Equal(3, blocks.Count);
        Assert.StartsWith("Ada: word", blocks[0]);
        Assert.EndsWith("Me: short reply", blocks[2]);
        Assert.All(blocks, b => Assert.All(b.Split('\n'), line => Assert.True(line.Split(' ').Length <= 11)));
    }

    [Fact]
    public void TheAnswerIsReadWhateverItsMarkdown()
    {
        const string answer = "**OVERVIEW:** The team set the beta date.\n### POINTS:\n- The beta ships on Monday.\n* release notes are almost done.\n" +
                              "DECISIONS:\n1. Ship on Monday.\nACTIONS:\n- None";
        var notes = Summary.Parse(answer);
        Assert.Equal("The team set the beta date.", notes.Overview);
        Assert.Equal(new[] { "The beta ships on Monday.", "Release notes are almost done." }, notes.Points);
        Assert.Equal(new[] { "Ship on Monday." }, notes.Decisions);
        Assert.Empty(notes.Actions);
    }

    [Fact]
    public void FrenchLabelsAndEmptyPartsAreRead()
    {
        var notes = Summary.Parse("Résumé : point d'étape.\nPoints clés :\n- La sortie est lundi.\nDécisions :\n- Aucune décision n'a été prise.\nÀ faire :\n- Paul : relire les notes.");
        Assert.Equal("Point d'étape.", notes.Overview);
        Assert.Equal(new[] { "La sortie est lundi." }, notes.Points);
        Assert.Empty(notes.Decisions);
        Assert.Equal(new[] { "Paul : relire les notes." }, notes.Actions);
    }

    [Fact]
    public void ACutOffLastLineIsDropped()
    {
        var notes = Summary.Parse("POINTS:\n- The beta ships on Monday.\n- Speaker 1 mentions");
        Assert.Equal(new[] { "The beta ships on Monday." }, notes.Points);
    }

    [Fact]
    public void NotesSurviveAFormatAndParseRoundTrip()
    {
        var notes = new CallNotes { Overview = "A sync.", Points = { "One", "Two" }, Decisions = { "Ship" }, Actions = { "Ada: write the notes" } };
        var back = Summary.Parse(Summary.Format(notes));
        Assert.Equal(notes.Overview, back.Overview);
        Assert.Equal(notes.Points, back.Points);
        Assert.Equal(notes.Decisions, back.Decisions);
        Assert.Equal(notes.Actions, back.Actions);
    }

    [Fact]
    public void TheFileHasTheTitleThenOnlyTheSectionsWithContent()
    {
        var record = new SessionRecord { Title = "Weekly sync", StartedAt = new DateTime(2026, 11, 13, 9, 0, 0, DateTimeKind.Utc) };
        var text = Summary.Text(new CallNotes { Overview = "Un point.", Points = { "Lundi." } }, record, "fr");
        Assert.StartsWith("Weekly sync — November 13, 2026 at ", text);
        Assert.Contains("\nRésumé\nUn point.\n", text);
        Assert.Contains("\nPoints clés\n- Lundi.\n", text);
        Assert.DoesNotContain("Décisions", text);
        Assert.DoesNotContain("À faire", text);
    }

    /// <summary>Model stand-in: notes for each block, then a merge of them.</summary>
    sealed class FakeModel : ISummaryModel
    {
        public readonly List<string> Prompts = new();
        public string? Ask(string instructions, string prompt, int maxTokens, CancellationToken cancel)
        {
            Prompts.Add(prompt);
            Assert.Contains("Write in French", instructions);
            return prompt.StartsWith("Here are the notes")
                ? "OVERVIEW: Toute la session.\nPOINTS:\n- Point fusionné.\nDECISIONS:\n- Paul relit les notes.\nACTIONS:\n- Paul : relire les notes."
                : $"OVERVIEW: Une partie.\nPOINTS:\n- Point {Prompts.Count}.\nDECISIONS:\nACTIONS:";
        }
    }

    [Fact]
    public void ALongCallIsReadInBlocksThenMerged()
    {
        var words = string.Join(" ", Enumerable.Repeat("on parle de la sortie et des notes", 40));
        var record = new SessionRecord { Title = "Point", Segments = { S(words, "Ada"), S(words, "Paul") } };
        var model = new FakeModel();
        var progress = new List<double>();
        var text = Summary.Write(record, model, 200, progress.Add)!;
        Assert.True(model.Prompts.Count >= 4);
        Assert.StartsWith("Part 1 of ", model.Prompts[0]);
        Assert.Contains("Here are the notes", model.Prompts[^1]);
        Assert.Contains("- Point fusionné.", text);
        Assert.Contains("À faire\n- Paul : relire les notes.", text);
        Assert.DoesNotContain("Décisions", text);  // the decision repeated the task: dropped
        Assert.Equal(1, progress[^1]);
    }

    [Fact]
    public void AShortSessionGetsNoSummary()
    {
        var record = new SessionRecord { Title = "Hi", Segments = { S("Hello there, see you tomorrow.") } };
        Assert.Null(Summary.Write(record, new FakeModel(), 2400, _ => { }));
    }

    [Fact]
    public void TheSummaryModelsGoFromSmallToExtraLarge()
    {
        Assert.Equal(new[] { "small", "medium", "large", "xlarge" }, ModelCatalog.SummaryModels.Select(m => m.Id));
        Assert.Equal("medium", new AppSettings().SummaryModel);
        Assert.True(new AppSettings().Summarize);
        Assert.Equal("Qwen3-14B-Q4_K_M.gguf", ModelCatalog.SummaryModel("xlarge").FileName);
        Assert.All(ModelCatalog.SummaryModels, m => Assert.StartsWith("https://huggingface.co/Qwen/", m.Url));
        L.Use("fr");
        try { Assert.Equal(new[] { "Petit", "Moyen", "Gros", "Très gros" }, ModelCatalog.SummaryModels.Select(m => L.SummarySize(m.Id))); }
        finally { L.Use("en"); }
    }
}
