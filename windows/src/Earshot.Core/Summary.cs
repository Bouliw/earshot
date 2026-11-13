using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Earshot.Core;

/// <summary>The notes of a call: what it was about, the key points, the decisions taken and who does what.</summary>
public sealed class CallNotes
{
    public string Overview { get; set; } = "";
    public List<string> Points { get; set; } = new();
    public List<string> Decisions { get; set; } = new();
    public List<string> Actions { get; set; } = new();

    public bool IsEmpty => Overview.Length == 0 && Points.Count == 0 && Decisions.Count == 0 && Actions.Count == 0;
}

/// <summary>A local language model, asked one question at a time in a fresh context.</summary>
public interface ISummaryModel
{
    /// <summary>The answer, or null when the model could not answer (the question did not fit, say).</summary>
    string? Ask(string instructions, string prompt, int maxTokens, CancellationToken cancel);
}

/// <summary>Summary.txt, as on the Mac: the transcript goes to the model in blocks it can read in one go, the model writes
/// notes for each block in a fixed form, and the notes are merged into the notes of the whole call. Written in the
/// language of the call.</summary>
public static class Summary
{
    public const string FileName = "Summary.txt";
    /// <summary>Below this, there is nothing worth summarizing.</summary>
    public const int MinimumWords = 30;

    public static string? Load(string? folder)
    {
        if (folder == null) return null;
        var path = Path.Combine(folder, FileName);
        try { return File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : null; }
        catch (IOException) { return null; }
    }

    static readonly HashSet<string> FrenchWords = new(StringComparer.Ordinal)
    {
        "le", "la", "les", "de", "des", "du", "et", "est", "je", "que", "qui", "pas", "pour", "on", "une", "un",
        "dans", "ça", "c'est", "vous", "nous", "il", "elle", "mais", "avec", "sur", "au", "ce", "en", "oui",
    };
    static readonly HashSet<string> EnglishWords = new(StringComparer.Ordinal)
    {
        "the", "and", "is", "to", "of", "that", "you", "it", "we", "in", "this", "for", "not", "have", "what",
        "are", "with", "on", "be", "was", "they", "so", "but", "yes", "i", "a", "do", "can", "my", "your",
    };

    static IEnumerable<string> Words(string text) =>
        Regex.Split(text.ToLowerInvariant().Replace('’', '\''), @"[^\p{L}']+").Where(w => w.Length > 0);

    /// <summary>"fr" when the transcript reads as French, else "en".</summary>
    public static string Language(IEnumerable<Segment> segments)
    {
        int fr = 0, en = 0;
        foreach (var w in segments.SelectMany(s => Words(s.Text)))
        {
            if (FrenchWords.Contains(w)) fr++;
            else if (EnglishWords.Contains(w)) en++;
        }
        return fr > en ? "fr" : "en";
    }

    public static int WordCount(IEnumerable<Segment> segments) =>
        segments.Sum(s => s.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length);

    /// <summary>The transcript as "Name: text" turns, in blocks of at most <paramref name="words"/> words. A turn longer than a
    /// block is cut between words.</summary>
    public static List<string> Blocks(IEnumerable<Segment> segments, int words)
    {
        var blocks = new List<string>();
        var current = new List<string>();
        var count = 0;
        void Flush()
        {
            if (current.Count > 0) blocks.Add(string.Join("\n", current));
            current.Clear();
            count = 0;
        }
        foreach (var turn in Turn.Group(segments))
        {
            var name = turn.Speaker ?? "?";
            var rest = turn.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
            while (rest.Count > 0)
            {
                if (count >= words) Flush();
                var take = Math.Min(rest.Count, words - count);
                current.Add(name + ": " + string.Join(" ", rest.Take(take)));
                count += take;
                rest.RemoveRange(0, take);
            }
        }
        Flush();
        return blocks;
    }

    static string LanguageName(string language) => language == "fr" ? "French" : "English";

    public static string Instructions(string language) =>
        $"You write the notes of a call or a class from its transcript. Write in {LanguageName(language)}. " +
        "Use only what is said in the transcript: never add facts, names, figures, dates or tasks that are not in it. " +
        "Refer to people only by the names at the start of the transcript lines (\"Speaker 1\", a first name…), exactly as " +
        "written there: never guess who is who from the title. When it is unclear who said something, say it without a name. " +
        "Be brief and concrete.";

    static string Form(string language) => language == "fr"
        ? "Réponds exactement sous cette forme, entièrement en français :\n" +
          "RÉSUMÉ : une ou deux phrases sur ce qui a été dit.\n" +
          "POINTS CLÉS :\n- un point important par ligne, en une phrase courte avec tes propres mots (pas de citation), 8 au plus\n" +
          "DÉCISIONS :\n- une décision par ligne : seulement un choix sur lequel les intervenants se sont mis d'accord, jamais une tâche ; laisse vide s'il n'y en a pas\n" +
          "À FAIRE :\n- une tâche par ligne, sous la forme « Nom : la tâche » en une phrase courte avec tes propres mots, à la troisième personne, " +
          "avec le nom tel qu'il est écrit dans la transcription et une échéance seulement si elle est dite ; laisse vide s'il n'y en a pas"
        : $"Answer in exactly this form, with these four labels in English and everything else in {LanguageName(language)}:\n" +
        "OVERVIEW: one or two sentences on what was discussed.\n" +
        "POINTS:\n- one important point per line, in a short sentence of your own (not a quote), at most 8\n" +
        "DECISIONS:\n- one decision per line: only a choice the speakers agreed on, never a task; leave this part empty when no decision was taken\n" +
        "ACTIONS:\n- one task someone agreed to do, per line, written as \"Name: the task\" in a short sentence of your own (not a quote), " +
        "with the name as written in the transcript and a deadline only if one is said; leave this part empty when there is none";

    public static string PartPrompt(string title, int part, int total, string block, string language)
    {
        var which = total > 1 ? $"Part {part} of {total} of the transcript" : "The transcript";
        return $"{which} of \"{title}\". Each line is \"Name: what they said\".\n\n{block}\n\n{Form(language)}";
    }

    public static string MergePrompt(string title, IReadOnlyList<CallNotes> notes, string language)
    {
        var parts = string.Join("\n\n", notes.Select((n, i) => $"Notes {i + 1}:\n{Format(n)}"));
        return $"Here are the notes of the successive parts of \"{title}\", in order.\n\n{parts}\n\n" +
               "Merge them into the notes of the whole session: keep only what matters most and remove repeats. " +
               $"At most 8 points, 6 decisions and 8 actions, one short sentence each. {Form(language)}";
    }

    /// <summary>Notes back in the fixed form, to merge them.</summary>
    public static string Format(CallNotes notes)
    {
        var sb = new StringBuilder();
        sb.Append("OVERVIEW: ").Append(notes.Overview).Append('\n').Append("POINTS:\n");
        foreach (var p in notes.Points) sb.Append("- ").Append(p).Append('\n');
        sb.Append("DECISIONS:\n");
        foreach (var d in notes.Decisions) sb.Append("- ").Append(d).Append('\n');
        sb.Append("ACTIONS:\n");
        foreach (var a in notes.Actions) sb.Append("- ").Append(a).Append('\n');
        return sb.ToString();
    }

    enum Part { Overview, Points, Decisions, Actions }

    static readonly (Part Part, string[] Names)[] Labels =
    {
        (Part.Overview, new[] { "overview", "summary", "résumé", "resume", "aperçu", "vue d'ensemble" }),
        (Part.Points, new[] { "points", "key points", "points clés", "points cles", "points importants" }),
        (Part.Decisions, new[] { "decisions", "décisions" }),
        (Part.Actions, new[] { "actions", "action items", "à faire", "a faire", "tâches", "taches", "next steps", "prochaines étapes" }),
    };

    static readonly HashSet<string> Nothing = new(StringComparer.Ordinal)
    {
        "none", "n/a", "nothing", "aucune", "aucun", "rien", "néant", "none noted", "aucune décision", "no decision", "no decisions",
    };

    /// <summary>"No decision was taken.", "Aucune action n'a été mentionnée.": the model saying a part is empty.</summary>
    static bool SaysNothing(string key)
    {
        var starts = new[] { "none", "no decision", "no action", "nothing", "aucune", "aucun", "rien", "pas de décision", "pas d'action", "n/a" };
        return key.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 8 && starts.Any(key.StartsWith);
    }

    /// <summary>Reads the model's answer. Labels may come with Markdown, in either language; empty items ("None") are dropped.</summary>
    public static CallNotes Parse(string text)
    {
        var notes = new CallNotes();
        Part? part = null;
        List<string>? lastList = null;
        void Add(string raw, Part p)
        {
            var item = raw.Trim();
            var key = item.ToLowerInvariant().Trim('.', '!', '(', ')', ' ');
            if (item.Length == 0 || Nothing.Contains(key) || SaysNothing(key)) return;
            item = char.ToUpper(item[0], CultureInfo.InvariantCulture) + item[1..];
            switch (p)
            {
                case Part.Overview: notes.Overview = notes.Overview.Length == 0 ? item : notes.Overview + " " + item; break;
                case Part.Points: notes.Points.Add(item); lastList = notes.Points; break;
                case Part.Decisions: notes.Decisions.Add(item); lastList = notes.Decisions; break;
                case Part.Actions: notes.Actions.Add(item); lastList = notes.Actions; break;
            }
        }
        foreach (var raw in text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            var bare = line.Trim('#', '*', '_', ' ').ToLowerInvariant();
            var matched = false;
            foreach (var (p, names) in Labels)
            {
                foreach (var name in names)
                {
                    if (!bare.StartsWith(name, StringComparison.Ordinal)) continue;
                    var after = bare[name.Length..].Trim('*', '_', ' ');
                    if (after.Length > 0 && !after.StartsWith(':')) continue;
                    part = p;
                    matched = true;
                    var colon = line.IndexOf(':');
                    if (colon >= 0)
                    {
                        var rest = line[(colon + 1)..].Trim('*', '_', ' ');
                        if (rest.Length > 0) Add(rest, p);
                    }
                    break;
                }
                if (matched) break;
            }
            if (matched || part is not { } current) continue;
            Add(Regex.Replace(line, @"^([-*•–]|\d+[.)])\s*", ""), current);
        }
        // An answer that ran out of room ends on a cut-off line: a last item of a few words is dropped.
        if (lastList is { Count: > 0 } && lastList[^1].Split(' ').Length <= 3 && !".!?)»\"".Contains(lastList[^1][^1]))
            lastList.RemoveAt(lastList.Count - 1);
        return notes;
    }

    /// <summary>Two lines saying mostly the same thing (most of the shorter one's words are in the other).</summary>
    public static bool Similar(string a, string b)
    {
        static HashSet<string> W(string s) => Regex.Split(s.ToLowerInvariant(), @"[^\p{L}]+").Where(w => w.Length > 3).ToHashSet();
        var x = W(a);
        var y = W(b);
        var smaller = x.Count <= y.Count ? x : y;
        return smaller.Count > 0 && x.Intersect(y).Count() / (double)smaller.Count >= 0.6;
    }

    public static (string Summary, string Points, string Decisions, string Actions) Headings(string language) =>
        language == "fr" ? ("Résumé", "Points clés", "Décisions", "À faire") : ("Summary", "Key points", "Decisions", "Action items");

    public static readonly HashSet<string> AllHeadings = new()
    {
        "Summary", "Key points", "Decisions", "Action items", "Résumé", "Points clés", "Décisions", "À faire",
    };

    /// <summary>Summary.txt: the title and date as in Transcript.txt, then the sections that have something in them.</summary>
    public static string Text(CallNotes notes, SessionRecord record, string language)
    {
        var h = Headings(language);
        var sb = new StringBuilder();
        sb.Append(record.Title).Append(" — ").Append(SessionStore.LongDate(record.StartedAt)).Append('\n');
        if (notes.Overview.Length > 0) sb.Append('\n').Append(h.Summary).Append('\n').Append(notes.Overview).Append('\n');
        foreach (var (title, items) in new[] { (h.Points, notes.Points), (h.Decisions, notes.Decisions), (h.Actions, notes.Actions) })
        {
            if (items.Count == 0) continue;
            sb.Append('\n').Append(title).Append('\n');
            foreach (var item in items) sb.Append("- ").Append(item).Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>The text of Summary.txt, or null when the session says too little. <paramref name="blockWords"/> is sized
    /// so a block, the instructions and the answer fit in the model's context.</summary>
    public static string? Write(SessionRecord record, ISummaryModel model, int blockWords, Action<double> progress, CancellationToken cancel = default)
    {
        if (WordCount(record.Segments) < MinimumWords) return null;
        var language = Language(record.Segments);
        var instructions = Instructions(language);
        var blocks = Blocks(record.Segments, blockWords);
        var steps = blocks.Count + (blocks.Count > 1 ? 1 : 0);
        var notes = new List<CallNotes>();
        for (var i = 0; i < blocks.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            var answer = model.Ask(instructions, PartPrompt(record.Title, i + 1, blocks.Count, blocks[i], language), 900, cancel);
            if (answer != null && Parse(answer) is { IsEmpty: false } n) notes.Add(n);
            progress((i + 1) / (double)steps);
        }
        // Merged a few at a time, so the notes given to the model always fit.
        while (notes.Count > 1)
        {
            cancel.ThrowIfCancellationRequested();
            var merged = new List<CallNotes>();
            var batch = new List<CallNotes>();
            void MergeBatch()
            {
                if (batch.Count == 0) return;
                if (batch.Count == 1) merged.Add(batch[0]);
                else
                {
                    var answer = model.Ask(instructions, MergePrompt(record.Title, batch, language), 900, cancel);
                    merged.Add(answer != null && Parse(answer) is { IsEmpty: false } n ? n : batch[0]);
                }
                batch = new List<CallNotes>();
            }
            foreach (var n in notes)
            {
                var words = batch.Append(n).Sum(x => Format(x).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length);
                if (words > blockWords && batch.Count > 0) MergeBatch();
                batch.Add(n);
            }
            MergeBatch();
            if (merged.Count >= notes.Count) { notes = merged.Take(1).ToList(); break; }
            notes = merged;
        }
        progress(1);
        if (notes.Count == 0) return null;
        var final = notes[0];
        final.Points = final.Points.Take(8).ToList();
        final.Actions = final.Actions.Take(8).ToList();
        final.Decisions = final.Decisions.Where(d => !final.Actions.Any(a => Similar(d, a))).Take(6).ToList();
        return Text(final, record, language);
    }
}
