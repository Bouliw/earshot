import AppKit
import Testing
@testable import Earshot

/// The live line, the subtitles and the transcript view's text.
@Suite struct LiveTextTests {
    @MainActor @Test func subtitlesKeepTheLastEightLinesButCountEveryOne() {
        let feed = SubtitleFeed()
        for i in 1...9 { feed.update("Phrase \(i)"); feed.commit() }
        #expect(feed.lines.count == 8 && feed.lines.first?.text == "Phrase 2" && feed.total == 9)
        feed.update("Still being said")
        feed.clear()
        feed.update("After clear")
        #expect(feed.lines.map(\.text) == ["After clear"] && feed.total == 1)
    }

    @MainActor @Test func subtitlesIgnoreBlankTextAndEndAPhraseAtAnyStop() {
        let feed = SubtitleFeed()
        feed.update("   ")
        #expect(feed.lines.isEmpty)
        for piece in ["  Really", "?", " Yes", "!", " Fine"] { feed.append(piece) }
        #expect(feed.lines.map(\.text) == ["Really?", "Yes!", "Fine"])
    }

    @Test(arguments: ["", "  ", "...", "[BLANK_AUDIO]", "(music)", "*sighs*", "You.", "Thanks for watching!", "Thank you for watching.",
                      "Subtitles by the Amara.org community", "Sous-titres réalisés par la communauté d'Amara.org"])
    func whisperHallucinationsAreNoise(text: String) {
        #expect(StreamingTranscriber.isNoise(text))
    }

    @Test(arguments: ["Thank you very much for your time.", "You know what I mean?", "Merci beaucoup.", "Okay", "Oui, d'accord."])
    func realSpeechIsNotNoise(text: String) {
        #expect(!StreamingTranscriber.isNoise(text))
    }

    @MainActor @Test func transcriptTextMarksEachTurnTheLiveLineAndEveryMatch() {
        let turns = [Turn(id: UUID(), speaker: "Jane Doe", start: 0, text: "Un café, s'il vous plaît."),
                     Turn(id: UUID(), speaker: "John", start: 30, text: "Voilà le CAFÉ.")]
        let doc = TranscriptDocument(turns: turns, startedAt: sessionStart, query: "cafe", live: ("John", "Et encore"))
        let text = doc.content.string as NSString
        #expect(doc.avatars.map(\.name) == ["Jane Doe", "John", "John"])
        #expect(doc.avatars.allSatisfy { text.substring(from: $0.location).hasPrefix($0.name ?? "") })
        // Matching ignores case and accents; the live line and the cursor are outside the committed text.
        var hits: [String] = []
        doc.content.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { hits.append(text.substring(with: range)) }
        }
        #expect(hits == ["café", "CAFÉ"])
        #expect(text.substring(to: doc.committedLength).hasSuffix("Voilà le CAFÉ."))
        #expect(doc.cursor == NSRange(location: text.length - 1, length: 1) && text.substring(from: text.length - 1) == "▍")

        let finished = TranscriptDocument(turns: turns, startedAt: sessionStart, query: "", live: nil)
        #expect(finished.cursor == nil && finished.committedLength == finished.content.length)
    }
}
