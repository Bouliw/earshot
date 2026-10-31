import Foundation
@testable import Earshot

/// Runs `body` with an empty folder in the temporary directory, removed afterwards.
func withTempFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appending(path: "earshot-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

/// A whole number of seconds, so the ISO 8601 date in a saved session reads back equal.
let sessionStart = Date(timeIntervalSince1970: 1_790_000_000)

func segment(_ start: TimeInterval, _ end: TimeInterval, _ speaker: String?, _ text: String, mic: Bool? = nil) -> Segment {
    Segment(start: start, end: end, speaker: speaker, text: text, mic: mic)
}

/// Two speakers, accents, a microphone line, and a line more than an hour in.
func sampleRecord(segments: [Segment]? = nil) -> SessionRecord {
    SessionRecord(title: "Stratégie digitale", appName: "Teams", bundleID: "com.microsoft.teams2", startedAt: sessionStart, duration: 3727,
                  segments: segments ?? [
                    segment(0, 4.2, "Jane Doe", "Bonjour à tous, démarrons."),
                    segment(4.2, 9.8, "Jane Doe", "Aujourd’hui : la stratégie digitale."),
                    segment(10, 12.5, "John Smith", "Merci Jane."),
                    segment(15, 17, "Moi", "Une question.", mic: true),
                    segment(3725.5, 3727, nil, "Dernière phrase."),
                  ])
}
