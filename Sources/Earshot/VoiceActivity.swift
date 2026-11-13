import Foundation
import FluidAudio

/// Where someone is actually speaking, from Silero's voice activity model (converted to Core ML by FluidAudio).
///
/// Whisper writes stock lines over breathing, typing and room noise: a microphone left open during a call
/// collects dozens of them. The sound level cannot tell that noise from a quiet voice; this model can, so
/// Whisper only gets the stretches where a voice is heard. The model (about 2 MB) is downloaded the first
/// time, into Application Support/Earshot/Voice activity, and runs on the Neural Engine.
actor VoiceActivity {
    static let shared = VoiceActivity()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Earshot/Voice activity")

    private var manager: VadManager?

    /// Stretches of speech in 16 kHz mono samples, in seconds, sorted, none longer than `maxLength`.
    func speech(in samples: [Float], maxLength: Double) async throws -> [(start: Double, end: Double)] {
        guard !samples.isEmpty else { return [] }
        let manager = try await prepared()
        let config = VadSegmentationConfig(
            minSpeechDuration: 0.25,   // a click or a breath is shorter than a word
            minSilenceDuration: 0.5,
            maxSpeechDuration: maxLength,
            speechPadding: 0.2         // keeps the first and last syllables
        )
        return try await manager.segmentSpeech(samples, config: config)
            .map { (start: $0.startTime, end: $0.endTime) }
            .filter { $0.end > $0.start }
    }

    private func prepared() async throws -> VadManager {
        if let manager { return manager }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let manager = try await VadManager(modelDirectory: Self.folder)
        self.manager = manager
        return manager
    }
}
