import Foundation
import Testing
@testable import Earshot

@Suite struct SummaryTests {
    func segment(_ text: String, _ speaker: String? = "Speaker 1") -> Segment { Segment(start: 0, end: 1, speaker: speaker, text: text) }

    @Test func theSummaryIsWrittenInTheLanguageOfTheCall() {
        #expect(Summary.language(of: [segment("Bon, on part sur une sortie lundi et je relis les notes cet après-midi.")]) == "fr")
        #expect(Summary.language(of: [segment("So we ship on Monday and I will review the notes this afternoon.")]) == "en")
    }

    @Test func blocksKeepEachTurnUnderItsSpeakerAndStayUnderTheWordLimit() {
        let long = Array(repeating: "word", count: 25).joined(separator: " ")
        let blocks = Summary.blocks([segment(long, "Ada"), segment("short reply", "Me")], words: 10)
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.split(separator: "\n").allSatisfy { $0.split(separator: " ").count <= 11 } })
        #expect(blocks[0].hasPrefix("Ada: word"))
        #expect(blocks[2].hasSuffix("Me: short reply"))
    }

    @Test func theAnswerIsReadWhateverItsMarkdown() {
        let answer = """
        **OVERVIEW:** The team set the beta date.
        ### POINTS:
        - The beta ships on Monday.
        * Release notes are almost done.
        DECISIONS:
        1. Ship on Monday.
        ACTIONS:
        - None
        """
        let notes = Summary.parse(answer)
        #expect(notes.overview == "The team set the beta date.")
        #expect(notes.points == ["The beta ships on Monday.", "Release notes are almost done."])
        #expect(notes.decisions == ["Ship on Monday."])
        #expect(notes.actions.isEmpty)
    }

    @Test func frenchLabelsAreReadToo() {
        let notes = Summary.parse("Résumé : Point d'étape.\nPoints clés :\n- La sortie est lundi.\nÀ faire :\n- Paul relit les notes.")
        #expect(notes.overview == "Point d'étape.")
        #expect(notes.points == ["La sortie est lundi."])
        #expect(notes.actions == ["Paul relit les notes."])
    }

    @Test func notesSurviveAFormatAndParseRoundTrip() {
        let notes = CallNotes(overview: "A sync.", points: ["One", "Two"], decisions: ["Ship"], actions: ["Ada: write the notes"])
        #expect(Summary.parse(Summary.format(notes)) == notes)
    }

    @Test func theFileHasTheTitleThenOnlyTheSectionsWithContent() {
        let record = SessionRecord(title: "Weekly sync", appName: "Teams", bundleID: "", startedAt: Date(timeIntervalSince1970: 0), duration: 60, segments: [])
        let text = Summary.text(CallNotes(overview: "Un point.", points: ["Lundi."]), record: record, language: "fr")
        #expect(text.hasPrefix("Weekly sync — "))
        #expect(text.contains("\nRésumé\nUn point.\n"))
        #expect(text.contains("\nPoints clés\n- Lundi.\n"))
        #expect(!text.contains("Décisions"))
        #expect(!text.contains("À faire"))
    }
}
