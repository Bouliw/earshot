import Foundation
import Testing
@testable import Earshot

/// What the user reads in Transcript.txt and in the exports from the Library.
@Suite struct TranscriptExportTests {
    let record = sampleRecord()

    /// The time of day of a line, formatted as the exports do.
    func stamp(_ t: TimeInterval) -> String { sessionStart.addingTimeInterval(t).formatted(date: .omitted, time: .standard) }

    /// Everything after the first line (title and date, which depend on the locale).
    func body(_ text: String) -> String { String(text.drop { $0 != "\n" }.dropFirst()) }

    @Test func textGroupsTurnsAndStampsEachWithItsTimeOfDay() {
        let text = SessionStore.text(record)
        #expect(text.hasPrefix("Stratégie digitale — "))
        #expect(body(text) == """

            [\(stamp(0))] Jane Doe
            Bonjour à tous, démarrons. Aujourd’hui : la stratégie digitale.

            [\(stamp(10))] John Smith
            Merci Jane.

            [\(stamp(15))] Moi
            Une question.

            [\(stamp(3725.5))]
            Dernière phrase.

            """)
    }

    @Test func markdownNamesUnknownSpeakersAndGivesTheDuration() {
        let markdown = SessionStore.markdown(record)
        let lines = markdown.components(separatedBy: "\n")
        #expect(lines[0] == "# Stratégie digitale")
        #expect(lines[2].hasPrefix("*Teams · ") && lines[2].hasSuffix(" · 1 h 02 min*"))
        #expect(markdown.contains("\n**Jane Doe** · \(stamp(0))\n\nBonjour à tous, démarrons. Aujourd’hui : la stratégie digitale.\n"))
        #expect(markdown.hasSuffix("\n**Unknown** · \(stamp(3725.5))\n\nDernière phrase.\n"))
    }

    @Test func subtitlesNumberEachSegmentAndCountPastTheHour() {
        let srt = SessionStore.srt(sampleRecord(segments: [
            segment(0, 4.2, "Jane Doe", "Bonjour à tous."),
            segment(59.9996, 61.0004, nil, "Rollover."),
            segment(3725.5, 3727, "John Smith", "Après une heure."),
        ]))
        #expect(srt == """
            1
            00:00:00,000 --> 00:00:04,200
            Jane Doe: Bonjour à tous.

            2
            00:01:00,000 --> 00:01:01,000
            Rollover.

            3
            01:02:05,500 --> 01:02:07,000
            John Smith: Après une heure.

            """)
    }

    @Test func emptySessionExportsOnlyItsHeader() {
        let empty = sampleRecord(segments: [])
        #expect(SessionStore.srt(empty) == "")
        #expect(SessionStore.text(empty).components(separatedBy: "\n").count == 2)
        #expect(SessionStore.markdown(empty).components(separatedBy: "\n").count == 4)
    }

    @Test(arguments: [(0.0, "0:00"), (59.9, "0:59"), (75, "1:15"), (3599.9, "59:59"), (3600, "1:00:00"), (3725, "1:02:05")])
    func clockShowsHoursOnlyWhenNeeded(seconds: TimeInterval, expected: String) {
        #expect(seconds.clock == expected)
    }

    @Test(arguments: [(0.0, "1 min"), (30, "1 min"), (59 * 60, "59 min"), (3600, "1 h 00 min"), (3727, "1 h 02 min"), (5400, "1 h 30 min"), (7260, "2 h 01 min")])
    func spokenDurationRoundsDownToMinutes(seconds: TimeInterval, expected: String) {
        #expect(seconds.spoken == expected)
    }
}

@Suite struct TurnGroupingTests {
    @Test func aTurnEndsTwoMinutesAfterItStartedEvenIfTheSpeakerKeepsTalking() {
        let turns = Turn.group([segment(0, 50, "A", "one"), segment(60, 110, "A", "two"), segment(119.9, 125, "A", "three"), segment(120, 130, "A", "four")])
        #expect(turns.map(\.text) == ["one two three", "four"])
        #expect(turns.map(\.start) == [0, 120])
    }

    @Test func aSpeakerWhoComesBackStartsANewTurn() {
        let turns = Turn.group([segment(0, 1, "A", "a1"), segment(1, 2, "B", "b"), segment(2, 3, "A", "a2"), segment(3, 4, nil, "x"), segment(4, 5, nil, "y")])
        #expect(turns.map(\.speaker) == ["A", "B", "A", nil])
        #expect(turns.last?.text == "x y")
    }

    @Test func aTurnKeepsTheIDOfItsFirstSegmentAndNothingMakesNoTurns() {
        let first = segment(0, 1, "A", "a"), second = segment(1, 2, "A", "b")
        #expect(Turn.group([first, second]).map(\.id) == [first.id])
        #expect(Turn.group([]).isEmpty)
    }
}
