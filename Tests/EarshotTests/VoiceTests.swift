import Foundation
import Testing
@testable import Earshot

/// Telling voices apart once the call is over: which voice said a line, and what each voice is called.
@Suite struct VoiceTests {
    let turns = [
        VoiceTurn(start: 0, end: 10, voice: "S1"),
        VoiceTurn(start: 10, end: 20, voice: "S2"),
        VoiceTurn(start: 20, end: 25, voice: "S1"),
    ]

    @Test func eachVoiceTakesTheTeamsNameHeardOverItsTurns() {
        let marks = [NameMark(time: 2, name: "Jane Doe"), NameMark(time: 6, name: "Jane Doe"), NameMark(time: 12, name: "Bob Smith"),
                     NameMark(time: 16, name: "Bob Smith"), NameMark(time: 21, name: "Jane Doe")]
        #expect(Voices.names(for: turns, marks: marks) == ["S1": "Jane Doe", "S2": "Bob Smith"])
    }

    @Test func voicesWithoutANameAreNumberedInTheOrderTheyFirstSpeak() {
        let marks = [NameMark(time: 12, name: "Bob Smith"), NameMark(time: 16, name: "Bob Smith")]
        let three = turns + [VoiceTurn(start: 25, end: 30, voice: "S3")]
        #expect(Voices.names(for: three, marks: marks) == ["S1": "Speaker 1", "S2": "Bob Smith", "S3": "Speaker 2"])
        #expect(Voices.names(for: turns, marks: []) == ["S1": "Speaker 1", "S2": "Speaker 2"])
        // One voice besides the user's microphone: the other side still gets a name to rename.
        let alone = [VoiceTurn(start: 0, end: 5, voice: "S1")]
        #expect(Voices.names(for: alone, marks: []) == [:])
        #expect(Voices.names(for: alone, marks: [], withUser: true) == ["S1": "Speaker 1"])
    }

    @Test func aSingleVoiceWithoutANameStaysUnnamed() {
        #expect(Voices.names(for: [VoiceTurn(start: 0, end: 60, voice: "S1")], marks: []).isEmpty)
    }

    @Test func oneStrayCaptionDoesNotNameAVoice() {
        #expect(Voices.names(for: turns, marks: [NameMark(time: 3, name: "Jane Doe")]) == ["S1": "Speaker 1", "S2": "Speaker 2"])
    }

    @Test func aLineGoesToTheVoiceHeardMostOverIt() {
        #expect(Voices.voice(from: 8, to: 14, in: turns) == "S2")
        #expect(Voices.voice(from: 1, to: 9, in: turns) == "S1")
        #expect(Voices.voice(from: 25.5, to: 26, in: turns) == "S1")   // just after a turn
        #expect(Voices.voice(from: 40, to: 42, in: turns) == nil)
    }

    @Test func overlapsAreTrimmedSoEachMomentHasOneVoice() {
        let trimmed = Voices.exclusive([VoiceTurn(start: 0, end: 5, voice: "A"), VoiceTurn(start: 4, end: 8, voice: "B"), VoiceTurn(start: 6, end: 7.9, voice: "A")])
        #expect(trimmed == [VoiceTurn(start: 0, end: 5, voice: "A"), VoiceTurn(start: 5, end: 8, voice: "B")])
    }

    @Test func linesFromTheMicrophoneKeepTheUsersName() {
        let lines = [Segment(start: 1, end: 4, speaker: nil, text: "Hello."), Segment(start: 11, end: 13, speaker: "Me", text: "Hi.", mic: true)]
        let named = Voices.label(lines, turns: turns, marks: [])
        #expect(named.map(\.speaker) == ["Speaker 1", "Me"])
    }

    @Test func renamingASpeakerChangesEveryLineAndCanMergeTwo() {
        var record = SessionRecord(title: "Call", appName: "Teams", bundleID: "", startedAt: Date(), duration: 30, segments: [
            Segment(start: 0, end: 1, speaker: "Speaker 1", text: "A."), Segment(start: 1, end: 2, speaker: "Speaker 2", text: "B."),
            Segment(start: 2, end: 3, speaker: "Speaker 1", text: "C."), Segment(start: 3, end: 4, speaker: nil, text: "D."),
        ])
        record.rename("Speaker 1", to: "Prof")
        #expect(record.segments.map(\.speaker) == ["Prof", "Speaker 2", "Prof", nil])
        record.rename("Speaker 2", to: "Prof")
        record.rename(nil, to: "Guest")
        #expect(record.speakers == ["Prof", "Guest"])
    }

    @Test func turnsOfTheSameVoiceAreJoinedThenCutBeforeTheLimit() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 60)
        let pieces = Chunker.pieces(turns: [VoiceTurn(start: 0, end: 4, voice: "A"), VoiceTurn(start: 4.5, end: 9, voice: "A"),
                                            VoiceTurn(start: 9, end: 12, voice: "B"), VoiceTurn(start: 12, end: 50, voice: "A")],
                                    samples: samples, maxLength: 15)
        #expect(pieces.first == Chunker.Piece(start: 0, end: 9, voice: "A"))
        #expect(pieces[1] == Chunker.Piece(start: 9, end: 12, voice: "B"))
        #expect(pieces.dropFirst(2).allSatisfy { $0.voice == "A" && $0.end - $0.start <= 15 })
        #expect(pieces.last?.end == 50)
    }

    @Test func withoutVoicesSoundIsFoundBetweenSilences() {
        var samples = [Float](repeating: 0, count: 16_000 * 10)
        for i in 16_000 * 2..<16_000 * 4 { samples[i] = i % 2 == 0 ? 0.05 : -0.05 }
        let pieces = Chunker.speech(samples, maxLength: 15)
        #expect(pieces.count == 1)
        #expect(abs((pieces.first?.start ?? 0) - 1.8) < 0.15 && abs((pieces.first?.end ?? 0) - 4.2) < 0.15)
    }

    @Test func sessionsFromOlderVersionsStillOpen() throws {
        let json = #"{"appName":"Teams","bundleID":"x","duration":1,"id":"0E9A5C0B-5E55-4B8B-8C6E-0C4F6B5E1A11","segments":[],"startedAt":"2026-09-21T09:00:00Z","title":"T"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))
        #expect(record.status == nil && record.names == nil && record.source == nil)
    }
}
