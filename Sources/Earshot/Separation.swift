import Foundation
import FluidAudio

/// A stretch of audio where one voice speaks. `voice` is an id from the speaker separation ("S1", "S2"...),
/// the same for every turn of that voice.
struct VoiceTurn: Hashable {
    var start: Double
    var end: Double
    var voice: String
}

/// Tells voices apart in a recording, on this Mac: pyannote's segmentation and speaker embeddings
/// converted to Core ML by FluidAudio, which run on the Neural Engine (a 1 h call takes seconds).
/// The models (about 40 MB) are downloaded the first time, into Application Support/Earshot/Speakers.
actor VoiceSeparator {
    static let shared = VoiceSeparator()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Earshot/Speakers")

    private var manager: OfflineDiarizerManager?

    /// Turns for 16 kHz mono samples, sorted by start, without overlaps.
    func turns(_ samples: [Float], progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [VoiceTurn] {
        let manager = try await prepared()
        let result = try await manager.process(audio: samples) { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
        }
        let turns = result.segments
            .map { VoiceTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), voice: $0.speakerId) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        return Voices.exclusive(turns)
    }

    private func prepared() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        // One voice per moment: the transcript gives each line to a single speaker anyway.
        let config = OfflineDiarizerConfig(postProcessing: .init(minGapDurationSeconds: 0.1, exclusiveSegments: true))
        let manager = OfflineDiarizerManager(config: config)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try await manager.prepareModels(directory: Self.folder)
        self.manager = manager
        return manager
    }
}

/// What the transcript does with the voice turns: which voice said a line, and what to call each voice.
enum Voices {
    /// Trims overlaps so each moment belongs to one voice (the one that was already speaking).
    static func exclusive(_ turns: [VoiceTurn]) -> [VoiceTurn] {
        var out: [VoiceTurn] = []
        for var t in turns.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, t.start < last.end { t.start = last.end }
            if t.end - t.start >= 0.2 { out.append(t) }
        }
        return out
    }

    /// The voice heard most over [start, end], else the nearest one within a second.
    static func voice(from start: Double, to end: Double, in turns: [VoiceTurn]) -> String? {
        var overlap: [String: Double] = [:]
        for t in turns where t.end > start && t.start < end {
            overlap[t.voice, default: 0] += min(t.end, end) - max(t.start, start)
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return best.key }
        let near = turns.map { t in (t.voice, max(t.start - end, start - t.end)) }.filter { $0.1 <= 1 }
        return near.min { $0.1 < $1.1 }?.0
    }

    /// A name for each voice. A voice takes the Teams name heard over most of its turns (several voices can
    /// end up with the same person, when one person was split in two); the others are "Speaker 1", "Speaker 2"...
    /// in the order they first speak. A single voice with no name gets none, unless the user's microphone was
    /// recorded apart (`withUser`): the other side is then "Speaker 1", to rename like any other.
    static func names(for turns: [VoiceTurn], marks: [NameMark], withUser: Bool = false) -> [String: String] {
        var order: [String] = []
        for t in turns where !order.contains(t.voice) { order.append(t.voice) }
        var votes: [String: [String: Int]] = [:]
        for m in marks {
            guard let t = turns.first(where: { m.time >= $0.start - 0.5 && m.time <= $0.end + 0.5 }) else { continue }
            votes[t.voice, default: [:]][m.name, default: 0] += 1
        }
        var names: [String: String] = [:]
        for voice in order {
            let counts = votes[voice] ?? [:]
            let total = counts.values.reduce(0, +)
            if let (name, n) = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), n >= 2, n * 2 >= total {
                names[voice] = name
            }
        }
        let unnamed = order.filter { names[$0] == nil }
        guard order.count > 1 || withUser else { return names }
        for (i, voice) in unnamed.enumerated() { names[voice] = String(localized: "Speaker \(i + 1)") }
        return names
    }

    /// Gives each line (outside the user's microphone) the name of the voice that said it.
    static func label(_ segments: [Segment], turns: [VoiceTurn], marks: [NameMark]) -> [Segment] {
        guard !turns.isEmpty else { return segments }
        let names = names(for: turns, marks: marks, withUser: segments.contains { $0.mic == true })
        return segments.map { s in
            guard s.mic != true, let voice = voice(from: s.start, to: s.end, in: turns) else { return s }
            var s = s
            s.speaker = names[voice] ?? s.speaker
            return s
        }
    }
}
