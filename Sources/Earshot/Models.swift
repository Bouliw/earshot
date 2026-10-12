import Foundation
import SwiftUI

/// One timestamped piece of transcript. Times are seconds from the start of the session.
struct Segment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?
    var text: String
}

/// Consecutive segments from the same speaker, as shown on screen.
struct Turn: Identifiable, Hashable {
    var id: UUID
    var speaker: String?
    var start: TimeInterval
    var text: String

    static func group(_ segments: [Segment]) -> [Turn] {
        var turns: [Turn] = []
        for s in segments {
            if let last = turns.last, last.speaker == s.speaker, s.start - last.start < 120 {
                turns[turns.count - 1].text += " " + s.text
            } else {
                turns.append(Turn(id: s.id, speaker: s.speaker, start: s.start, text: s.text))
            }
        }
        return turns
    }
}

/// Everything saved about a session, stored as `.earshot.json` in the session folder.
struct SessionRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var appName: String
    var bundleID: String
    var startedAt: Date
    var duration: TimeInterval
    var segments: [Segment]
    /// Not stored: where the record was loaded from.
    var folder: URL? = nil

    enum CodingKeys: String, CodingKey { case id, title, appName, bundleID, startedAt, duration, segments }

    /// Name of the library group (the calendar event the session was filed under).
    var group: String { folder?.deletingLastPathComponent().lastPathComponent ?? title }
}

extension TimeInterval {
    /// 75 -> "1:15", 3725 -> "1:02:05"
    var clock: String {
        let s = Int(self.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 5400 -> "1 h 30 min"
    var spoken: String {
        let m = Int(self / 60)
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60)) min" : "\(max(m, 1)) min"
    }
}

/// Stable color per speaker name (String.hashValue is randomized per launch, so not usable here).
enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .pink, .green, .purple, .teal, .indigo, .mint, .red, .cyan]
    static func of(_ name: String?) -> Color {
        guard let name else { return .secondary }
        let h = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return palette[Int(h % UInt32(palette.count))]
    }
}

/// The macOS 27 SDK turns `@State` into a macro whose plugin only ships with Xcode. This alias reaches the
/// underlying property wrapper, so the app builds with the Command Line Tools alone.
typealias ViewState<Value> = SwiftUI.State<Value>
