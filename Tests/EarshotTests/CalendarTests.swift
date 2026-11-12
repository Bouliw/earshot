import Foundation
import Testing
@testable import Earshot

/// Which calendar event a recording is filed under, and where it goes.
@Suite struct CalendarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ title: String, from start: Double, to end: Double, details: String = "") -> CalendarEvent {
        CalendarEvent(title: title, start: now.addingTimeInterval(start * 60), end: now.addingTimeInterval(end * 60), details: details)
    }

    @Test func aTeamsMeetingIsNotFiledUnderAWhatsAppCallStillOnTheCalendar() {
        let call = event("Call with Sam (Tokyo)", from: -40, to: 5, details: "Message him on WhatsApp before calling")
        let meeting = event("Team weekly", from: -5, to: 55)
        #expect(CalendarLookup.pick([call, meeting], app: "com.microsoft.teams2 Microsoft Teams", now: now) == meeting)
        // Alone at that time, an event is taken as it is: the app only settles overlaps.
        #expect(CalendarLookup.pick([call], app: "com.microsoft.teams2 Microsoft Teams", now: now) == call)
        let other = event("Call with Ana", from: -20, to: 30, details: "Zoom link")
        #expect(CalendarLookup.pick([call, other], app: "com.microsoft.teams2 Microsoft Teams", now: now) == other)
        #expect(CalendarLookup.pick([call, meeting], app: "net.whatsapp.WhatsApp WhatsApp", now: now) == call)
    }

    @Test func theEventNamingTheAppWinsThenTheLatestToStart() {
        let ending = event("Planning", from: -50, to: 10)
        let starting = event("Review", from: 10, to: 60)
        #expect(CalendarLookup.pick([ending, starting], app: "com.apple.Safari Safari", now: now) == starting)
        let linked = event("Client call", from: -50, to: 10, details: "https://teams.microsoft.com/l/meetup-join/abc")
        #expect(CalendarLookup.pick([linked, starting], app: "com.microsoft.teams2 Microsoft Teams", now: now) == linked)
    }

    @Test func doneToDosAndFinishedEventsAreNotMeetings() {
        let todo = event("✅ Tutor: choices sent", from: -10, to: 20)
        let past = event("Breakfast", from: -60, to: -1)
        #expect(CalendarLookup.pick([todo, past], app: nil, now: now) == nil)
    }

    @Test func classesAreTheEventsFiledBySchool() {
        #expect(CalendarLookup.isClass("GEM : Real World Content Marketing - Session 2"))
        #expect(CalendarLookup.isClass("SCHOOL : Content Strategy - Session 2"))
        #expect(!CalendarLookup.isClass("Nordine Dani (Datadog, Dublin) : call to set up"))
        #expect(!CalendarLookup.isClass("Auto · Bluesky : repost"))
        #expect(!CalendarLookup.isClass("Call with Sam (Tokyo) – WhatsApp"))
    }

    @Test func callsGoToTheirOwnFolderWhenOneIsSet() {
        let defaults = UserDefaults(suiteName: "earshot-tests-\(UUID().uuidString)")!
        defaults.set("/tmp/Classes", forKey: Pref.folder)
        #expect(Pref.base(forClass: false, defaults: defaults).path == "/tmp/Classes")
        defaults.set("/tmp/Calls", forKey: Pref.callsFolder)
        #expect(Pref.base(forClass: false, defaults: defaults).path == "/tmp/Calls")
        #expect(Pref.base(forClass: true, defaults: defaults).path == "/tmp/Classes")
    }
}

@Suite struct HallucinationTests {
    func line(_ text: String, mic: Bool = true, at t: Double) -> Segment {
        Segment(start: t, end: t + 1, speaker: mic ? "Me" : nil, text: text, mic: mic ? true : nil)
    }

    @Test func aShortLineLoopingOnSilenceIsDropped() {
        let loop = (0..<12).map { line("Merci.", at: 100 + Double($0)) }
        let kept = [line("Bonne journée, bye bye", at: 90)] + loop
        #expect(StreamingTranscriber.droppingLoops(kept).map(\.text) == ["Bonne journée, bye bye"])
    }

    @Test func realRepliesStay() {
        let talk = [line("Merci.", at: 1), line("C'est noté", mic: false, at: 2), line("Merci.", at: 3)]
            + (0..<4).map { line("Oui.", at: 4 + Double($0)) }
        #expect(StreamingTranscriber.droppingLoops(talk) == talk)
    }

    @Test func stockThanksAreRecognised() {
        #expect(StreamingTranscriber.isStock("Merci."))
        #expect(StreamingTranscriber.isStock(" Thank you. "))
        #expect(!StreamingTranscriber.isStock("Merci pour ta self-introduction"))
    }
}
