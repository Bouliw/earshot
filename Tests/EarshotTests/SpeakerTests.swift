import Foundation
import SwiftUI
import Testing
@testable import Earshot

@Suite struct SpeakerTests {
    @Test(arguments: [
        ("DUBOIS-EXTERNE Éloïse", "Éloïse Dubois"),
        ("MÜLLER Hans", "Hans Müller"),
        ("DUPONT-DURAND Jean-Pierre", "Jean-Pierre Dupont-Durand"),
        ("BOB", "BOB"),
        ("", ""),
    ])
    func teamsNamesBecomeFirstnameLastname(raw: String, expected: String) {
        #expect(TeamsCaptions.displayName(raw) == expected)
    }

    @Test func bothTeamsAppsAreRecognizedAndOthersAreNot() {
        #expect(TeamsCaptions.handles("com.microsoft.teams2") && TeamsCaptions.handles("com.microsoft.teams"))
        #expect(!TeamsCaptions.handles("com.microsoft.Word") && !TeamsCaptions.handles("us.zoom.xos"))
    }

    @Test func calendarTitlesBecomeFolderNames() {
        #expect(CalendarLookup.courseName("École de commerce : Stratégie digitale - Séance 3") == "Stratégie digitale")
        #expect(CalendarLookup.courseName("Data-driven marketing") == "Data-driven marketing")
        #expect(CalendarLookup.courseName("  Weekly sync  ") == "Weekly sync")
        #expect(CalendarLookup.courseName("") == "")
    }

    @Test func theNameHeardMostWinsOverTheOneHeardLastAndCaptionLagIsRemoved() {
        var timeline = SpeakerTimeline()
        timeline.add(10, "A"); timeline.add(11, "A"); timeline.add(12, "B")
        #expect(timeline.marks.map(\.time) == [8.5, 9.5, 10.5])
        #expect(timeline.speaker(from: 8, to: 12) == "A")
        #expect(timeline.latest == "B")
        #expect(SpeakerTimeline().latest == nil && SpeakerTimeline().speaker(from: 0, to: 5) == nil)
    }

    /// `String.hashValue` changes at every launch: a name must keep its color from one session to the next.
    @Test func aSpeakerKeepsTheSameColor() {
        #expect(SpeakerColor.of("A") == .pink)
        #expect(SpeakerColor.of("Jane Doe") == SpeakerColor.of("Jane Doe"))
        #expect(SpeakerColor.of(nil) == .secondary)
    }
}
