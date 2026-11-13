import Foundation
import FoundationModels

/// The notes of a call: what it was about, the key points, the decisions taken and who does what.
struct CallNotes: Equatable {
    var overview = ""
    var points: [String] = []
    var decisions: [String] = []
    var actions: [String] = []

    var isEmpty: Bool { overview.isEmpty && points.isEmpty && decisions.isEmpty && actions.isEmpty }
}

/// Summary.txt: the text side of the summary, kept apart from the model so it can be tested. The model gets the
/// transcript in blocks it can read in one go, writes notes for each block in a fixed form, and the notes are then
/// merged into the notes of the whole call.
enum Summary {
    static let fileName = "Summary.txt"
    /// Below this, there is nothing worth summarizing.
    static let minimumWords = 30

    static func url(in folder: URL) -> URL { folder.appending(path: fileName) }

    static func load(_ folder: URL?) -> String? {
        guard let folder else { return nil }
        return try? String(contentsOf: url(in: folder), encoding: .utf8)
    }

    /// "fr" when the transcript reads as French, else "en": the summary is written in the language of the call.
    static func language(of segments: [Segment]) -> String {
        let french: Set<String> = ["le", "la", "les", "de", "des", "du", "et", "est", "je", "que", "qui", "pas", "pour", "on", "une", "un",
                                   "dans", "ça", "c'est", "vous", "nous", "il", "elle", "mais", "avec", "sur", "au", "ce", "en", "oui"]
        let english: Set<String> = ["the", "and", "is", "to", "of", "that", "you", "it", "we", "in", "this", "for", "not", "have", "what",
                                    "are", "with", "on", "be", "was", "they", "so", "but", "yes", "i", "a", "do", "can", "my", "your"]
        var fr = 0, en = 0
        for s in segments {
            for word in s.text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }) {
                let w = word.replacingOccurrences(of: "’", with: "'")
                if french.contains(w) { fr += 1 } else if english.contains(w) { en += 1 }
            }
        }
        return fr > en ? "fr" : "en"
    }

    static func wordCount(_ segments: [Segment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// The transcript as "Name: text" turns, cut into blocks of at most `words` words. A turn longer than a block is
    /// cut between words.
    static func blocks(_ segments: [Segment], words: Int) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var count = 0
        func flush() {
            if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
            current = []; count = 0
        }
        for turn in Turn.group(segments) {
            let name = turn.speaker ?? "?"
            var rest = turn.text.split(whereSeparator: \.isWhitespace).map(String.init)
            while !rest.isEmpty {
                if count >= words { flush() }
                let take = min(rest.count, words - count)
                current.append("\(name): " + rest.prefix(take).joined(separator: " "))
                count += take
                rest.removeFirst(take)
            }
        }
        flush()
        return blocks
    }

    private static func languageName(_ language: String) -> String { language == "fr" ? "French" : "English" }

    static func instructions(language: String) -> String {
        """
        You write the notes of a call or a class from its transcript. Write in \(languageName(language)). \
        Use only what is said in the transcript: never add facts, names, figures, dates or tasks that are not in it. \
        Refer to people only by the names at the start of the transcript lines ("Speaker 1", a first name…), exactly as \
        written there: never guess who is who from the title. When it is unclear who said something, say it without a name. \
        Be brief and concrete.
        """
    }

    private static func form(_ language: String) -> String {
        """
        Answer in exactly this form, with these four labels in English and everything else in \(languageName(language)):
        OVERVIEW: one or two sentences on what was discussed.
        POINTS:
        - one important point per line, in a short sentence of your own (not a quote), at most 8
        DECISIONS:
        - one decision per line: only a choice the speakers agreed on, never a task; leave this part empty when no decision was taken
        ACTIONS:
        - one task someone agreed to do, per line, written as "Name: the task" in a short sentence of your own (not a quote), with the name as written in the transcript and a deadline only if one is said; leave this part empty when there is none
        """
    }

    static func partPrompt(title: String, part: Int, of total: Int, block: String, language: String) -> String {
        let which = total > 1 ? "Part \(part) of \(total) of the transcript" : "The transcript"
        return "\(which) of \"\(title)\". Each line is \"Name: what they said\".\n\n\(block)\n\n\(form(language))"
    }

    static func mergePrompt(title: String, notes: [CallNotes], language: String) -> String {
        let parts = notes.enumerated().map { "Notes \($0.offset + 1):\n\(format($0.element))" }.joined(separator: "\n\n")
        return """
        Here are the notes of the successive parts of "\(title)", in order.

        \(parts)

        Merge them into the notes of the whole session: keep only what matters most and remove repeats. At most 8 points, \
        6 decisions and 8 actions, one short sentence each. \(form(language))
        """
    }

    /// Notes back in the fixed form, to merge them.
    static func format(_ notes: CallNotes) -> String {
        var out = "OVERVIEW: \(notes.overview)\nPOINTS:\n"
        out += notes.points.map { "- \($0)\n" }.joined()
        out += "DECISIONS:\n" + notes.decisions.map { "- \($0)\n" }.joined()
        out += "ACTIONS:\n" + notes.actions.map { "- \($0)\n" }.joined()
        return out
    }

    /// Reads the model's answer. Labels may come with Markdown, in either language; empty items ("None") are dropped.
    static func parse(_ text: String) -> CallNotes {
        enum Part { case overview, points, decisions, actions }
        let labels: [(Part, [String])] = [
            (.overview, ["overview", "summary", "résumé", "resume", "aperçu", "vue d'ensemble"]),
            (.points, ["points", "key points", "points clés", "points cles", "points importants"]),
            (.decisions, ["decisions", "décisions"]),
            (.actions, ["actions", "action items", "à faire", "a faire", "tâches", "taches", "next steps", "prochaines étapes"]),
        ]
        let nothing: Set<String> = ["none", "n/a", "nothing", "aucune", "aucun", "rien", "néant", "none noted", "aucune décision", "no decision", "no decisions"]
        // "No decision was taken.", "Aucune action n'a été mentionnée." : the model saying a part is empty.
        func saysNothing(_ key: String) -> Bool {
            let starts = ["none", "no decision", "no action", "nothing", "aucune", "aucun", "rien", "pas de décision", "pas d'action", "n/a"]
            return key.split(separator: " ").count <= 8 && starts.contains { key.hasPrefix($0) }
        }
        var notes = CallNotes()
        var part: Part?
        var lastList: WritableKeyPath<CallNotes, [String]>?
        func add(_ item: String, to p: Part) {
            let text = item.trimmingCharacters(in: .whitespaces)
            let key = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!()"))
            guard !text.isEmpty, !nothing.contains(key), !saysNothing(key) else { return }
            let item = text.prefix(1).uppercased() + text.dropFirst()
            switch p {
            case .overview: notes.overview = notes.overview.isEmpty ? item : notes.overview + " " + item
            case .points: notes.points.append(item); lastList = \.points
            case .decisions: notes.decisions.append(item); lastList = \.decisions
            case .actions: notes.actions.append(item); lastList = \.actions
            }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ ")).lowercased()
            var matched = false
            for (p, names) in labels {
                for name in names where bare.hasPrefix(name) {
                    let after = bare.dropFirst(name.count).trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
                    guard after.isEmpty || after.hasPrefix(":") else { continue }
                    part = p
                    matched = true
                    // "OVERVIEW: text" on the same line.
                    if let colon = line.firstIndex(of: ":") {
                        let rest = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
                        if !rest.isEmpty { add(rest, to: p) }
                    }
                    break
                }
                if matched { break }
            }
            if matched { continue }
            guard let part else { continue }
            line = line.replacingOccurrences(of: #"^([-*•–]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            add(line, to: part)
        }
        // An answer that ran out of room ends on a cut-off line: a last item of a few words is dropped.
        if let path = lastList, let last = notes[keyPath: path].last, last.split(separator: " ").count <= 3,
           !(last.last.map { ".!?)»\"".contains($0) } ?? false) {
            notes[keyPath: path].removeLast()
        }
        if let first = notes.overview.first, first.isLowercase { notes.overview = first.uppercased() + notes.overview.dropFirst() }
        return notes
    }

    /// Two lines saying mostly the same thing (most of the shorter one's words are in the other).
    static func similar(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 3 }) }
        let x = words(a), y = words(b)
        guard let smaller = [x, y].min(by: { $0.count < $1.count }), !smaller.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(smaller.count) >= 0.6
    }

    static func headings(_ language: String) -> (summary: String, points: String, decisions: String, actions: String) {
        language == "fr" ? ("Résumé", "Points clés", "Décisions", "À faire") : ("Summary", "Key points", "Decisions", "Action items")
    }

    /// Summary.txt: the title and date as in Transcript.txt, then the sections that have something in them.
    static func text(_ notes: CallNotes, record: SessionRecord, language: String) -> String {
        let h = headings(language)
        var out = "\(record.title) — \(record.startedAt.formatted(date: .long, time: .shortened))\n"
        if !notes.overview.isEmpty { out += "\n\(h.summary)\n\(notes.overview)\n" }
        for (title, items) in [(h.points, notes.points), (h.decisions, notes.decisions), (h.actions, notes.actions)] where !items.isEmpty {
            out += "\n\(title)\n" + items.map { "- \($0)\n" }.joined()
        }
        return out
    }

    /// Every heading, in both languages: shown in bold in the app.
    static let allHeadings: Set<String> = ["Summary", "Key points", "Decisions", "Action items", "Résumé", "Points clés", "Décisions", "À faire"]
}

/// Writes Summary.txt with Apple's on-device model (Apple Intelligence). Nothing leaves the Mac. The model reads about
/// 4,000 tokens at a time, so a long call is summarized block by block, then the notes are merged.
enum CallSummarizer {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Words per block: the block, the instructions and the answer fit in the model's context, French included.
    static let blockWords = 1100

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { String(localized: "Summaries need Apple Intelligence, turned on in System Settings.") }
    }

    /// The text of Summary.txt, or nil when the session says too little to summarize.
    static func summarize(_ record: SessionRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        guard Summary.wordCount(record.segments) >= Summary.minimumWords else { return nil }
        guard isAvailable else { throw Failure.unavailable }
        let language = Summary.language(of: record.segments)
        let blocks = Summary.blocks(record.segments, words: blockWords)
        let steps = Double(blocks.count + (blocks.count > 1 ? 1 : 0))
        var notes: [CallNotes] = []
        for (i, block) in blocks.enumerated() {
            try Task.checkCancellation()
            if let n = await readBlock(block, title: record.title, part: i + 1, of: blocks.count, language: language), !n.isEmpty { notes.append(n) }
            progress(Double(i + 1) / steps)
        }
        // Merged a few at a time, so the notes given to the model always fit.
        while notes.count > 1 {
            var merged: [CallNotes] = []
            var batch: [CallNotes] = []
            func mergeBatch() async throws {
                guard !batch.isEmpty else { return }
                if batch.count == 1 { merged.append(batch[0]) }
                else if case let .notes(n)? = await ask(Summary.mergePrompt(title: record.title, notes: batch, language: language), language: language), !n.isEmpty { merged.append(n) }
                else { merged.append(contentsOf: batch.prefix(1)) }
                batch = []
            }
            for n in notes {
                let words = (batch + [n]).map { Summary.format($0).split(whereSeparator: \.isWhitespace).count }.reduce(0, +)
                if words > blockWords, !batch.isEmpty { try await mergeBatch() }
                batch.append(n)
            }
            try await mergeBatch()
            if merged.count >= notes.count { notes = Array(merged.prefix(1)); break }
            notes = merged
        }
        progress(1)
        guard var final = notes.first else { return nil }
        final.decisions = final.decisions.filter { d in !final.actions.contains { Summary.similar(d, $0) } }
        final.points = Array(final.points.prefix(8))
        final.decisions = Array(final.decisions.prefix(6))
        final.actions = Array(final.actions.prefix(8))
        return Summary.text(final, record: record, language: language)
    }

    /// The notes of one block. A block too long once tokenized is cut in two and each half is read on its own;
    /// a block the model refuses (its guardrails) is skipped, and the summary is made from the rest.
    private static func readBlock(_ block: String, title: String, part: Int, of total: Int, language: String, depth: Int = 0) async -> CallNotes? {
        switch await ask(Summary.partPrompt(title: title, part: part, of: total, block: block, language: language), language: language) {
        case let .notes(n)?:
            return n
        case .tooLong? where depth < 2:
            let lines = block.split(separator: "\n").map(String.init)
            guard lines.count > 1 else { return nil }
            let middle = lines.count / 2
            let first = await readBlock(lines[..<middle].joined(separator: "\n"), title: title, part: part, of: total, language: language, depth: depth + 1)
            let second = await readBlock(lines[middle...].joined(separator: "\n"), title: title, part: part, of: total, language: language, depth: depth + 1)
            let both = [first, second].compactMap { $0 }.filter { !$0.isEmpty }
            guard both.count == 2 else { return both.first }
            return CallNotes(overview: both[0].overview, points: both[0].points + both[1].points,
                             decisions: both[0].decisions + both[1].decisions, actions: both[0].actions + both[1].actions)
        default:
            return nil
        }
    }

    private enum Answer { case notes(CallNotes), tooLong }

    /// One question in a fresh session; nil when the model could not answer.
    private static func ask(_ prompt: String, language: String) async -> Answer? {
        let session = LanguageModelSession(model: .default, instructions: Summary.instructions(language: language))
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 900))
            return .notes(Summary.parse(response.content))
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { return .tooLong }
            return nil
        } catch {
            return nil
        }
    }
}
