import AVFoundation
import Foundation
import whisper

/// Reads the sound of any audio or video file macOS can open, as 16 kHz mono samples (all tracks mixed).
enum AudioFile {
    enum Failure: LocalizedError {
        case noAudio(String)
        var errorDescription: String? {
            switch self { case let .noAudio(name): String(localized: "\(name) has no sound Earshot can read.") }
        }
    }

    static func samples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.noAudio(url.lastPathComponent) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.noAudio(url.lastPathComponent) }
        var out: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            out += chunk
        }
        if reader.status == .failed { throw reader.error ?? Failure.noAudio(url.lastPathComponent) }
        return out
    }

    /// Writes samples as the compact AAC file every session keeps (Audio.m4a).
    static func write(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: Recorder.audioSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for start in stride(from: 0, to: samples.count, by: 160_000) {
            if let buffer = Resampler.buffer(Array(samples[start..<min(start + 160_000, samples.count)])) { try file.write(from: buffer) }
        }
    }
}

/// Where to cut a recording into pieces Whisper transcribes one at a time.
enum Chunker {
    static let rate = 16_000.0

    struct Piece: Hashable {
        var start: Double
        var end: Double
        var voice: String?
    }

    /// One piece per voice turn, joined with the next turn of the same voice when the pause is short,
    /// and cut at the quietest moment once longer than `maxLength`. Short pieces give each sentence its
    /// own language; long ones give Whisper more context.
    static func pieces(turns: [VoiceTurn], samples: [Float], maxLength: Double) -> [Piece] {
        var joined: [Piece] = []
        for t in turns {
            if var last = joined.last, last.voice == t.voice, t.start - last.end < 0.8, t.end - last.start <= maxLength {
                last.end = t.end
                joined[joined.count - 1] = last
            } else {
                joined.append(Piece(start: t.start, end: t.end, voice: t.voice))
            }
        }
        return joined.flatMap { split($0, samples: samples, maxLength: maxLength) }
    }

    /// Without voices: where there is sound, found with the level of each 100 ms.
    static func speech(_ samples: [Float], maxLength: Double, level: Float? = nil) -> [Piece] {
        let window = Int(rate / 10)
        let levels = stride(from: 0, to: samples.count, by: window).map { rms(samples[$0..<min($0 + window, samples.count)]) }
        // Quiet recordings (a phone memo) get a lower bar than call audio.
        let loud = levels.sorted().dropFirst(levels.count * 9 / 10).first ?? 0
        let threshold = level ?? max(0.002, min(0.004, loud / 10))
        var regions: [Piece] = []
        for (i, l) in levels.enumerated() where l > threshold {
            let t = Double(i) / 10
            if var last = regions.last, t - last.end < 0.8 { last.end = t + 0.1; regions[regions.count - 1] = last }
            else { regions.append(Piece(start: t, end: t + 0.1, voice: nil)) }
        }
        let duration = Double(samples.count) / rate
        return regions
            .map { Piece(start: max(0, $0.start - 0.2), end: min(duration, $0.end + 0.2), voice: nil) }
            .filter { $0.end - $0.start >= 0.4 }
            .flatMap { split($0, samples: samples, maxLength: maxLength) }
    }

    /// Where a voice is heard, found by the voice activity model. Falls back on the sound level when the
    /// model cannot load (no network for its first download, say).
    static func voiced(_ samples: [Float], maxLength: Double, level: Float? = nil) async -> [Piece] {
        guard let regions = try? await VoiceActivity.shared.speech(in: samples, maxLength: maxLength) else {
            return speech(samples, maxLength: maxLength, level: level)
        }
        return regions
            .map { Piece(start: $0.start, end: $0.end, voice: nil) }
            .flatMap { split($0, samples: samples, maxLength: maxLength) }
    }

    /// Cuts a long piece in the quietest 100 ms of the last 5 s before each `maxLength`.
    static func split(_ piece: Piece, samples: [Float], maxLength: Double) -> [Piece] {
        var out: [Piece] = []
        var start = piece.start
        while piece.end - start > maxLength {
            var best = start + maxLength, bestLevel = Float.greatestFiniteMagnitude
            var t = start + maxLength - 5
            while t + 0.1 <= start + maxLength {
                let a = Int(t * rate), b = min(samples.count, Int((t + 0.1) * rate))
                if a < b { let l = rms(samples[a..<b]); if l < bestLevel { bestLevel = l; best = t + 0.05 } }
                t += 0.1
            }
            out.append(Piece(start: start, end: best, voice: piece.voice))
            start = best
        }
        out.append(Piece(start: start, end: piece.end, voice: piece.voice))
        return out
    }

    static func rms(_ s: ArraySlice<Float>) -> Float { s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count)) }
}

extension Whisper {
    /// The language spoken in `samples` and how sure Whisper is (0...1).
    func language(of samples: [Float]) -> (code: String, probability: Float)? {
        guard let ctx else { return nil }
        let threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        let mel = samples.withUnsafeBufferPointer { whisper_pcm_to_mel(ctx, $0.baseAddress, Int32($0.count), threads) }
        guard mel == 0 else { return nil }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let id = whisper_lang_auto_detect(ctx, 0, threads, &probabilities)
        guard id >= 0, Int(id) < probabilities.count, let code = whisper_lang_str(id) else { return nil }
        return (String(cString: code), probabilities[Int(id)])
    }
}

/// Transcribes a whole recording once it is over: voices first, then each piece in its own language.
enum BatchTranscriber {
    struct Input {
        /// The app's sound (or the imported file).
        var samples: [Float]
        /// The user's microphone, kept apart so it is never mistaken for another voice.
        var mic: [Float]?
        var marks: [NameMark]
        var language: String          // "auto", "en", "fr"
        var separateVoices: Bool
        var model: URL
        /// Awaited before each piece: holds the work while a recording runs.
        var pause: @Sendable () async -> Void = {}
    }

    /// Progress goes 0...1: voices take the first tenth, transcription the rest.
    static func run(_ input: Input, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        await input.pause()
        var turns: [VoiceTurn] = []
        if input.separateVoices {
            // A failure here (no network for the first download, say) still leaves a transcript, without voices.
            turns = (try? await VoiceSeparator.shared.turns(input.samples) { progress($0 * 0.1) }) ?? []
        }
        progress(0.1)
        let maxLength = input.language == "auto" ? 15.0 : 25.0
        let pieces = turns.isEmpty
            ? await Chunker.voiced(input.samples, maxLength: maxLength)
            : Chunker.pieces(turns: turns, samples: input.samples, maxLength: maxLength)
        // The microphone is never muted: the app's sound is taken out of it, so the user's words stay even when they
        // speak over the other side. It also hears their breathing, typing and room noise between their sentences:
        // only the stretches where the voice model hears someone go to Whisper.
        let micTrack = input.mic.map { EchoCanceller.clean(mic: $0, reference: input.samples) }
        var micPieces: [Chunker.Piece] = []
        if let micTrack {
            micPieces = await Chunker.voiced(micTrack, maxLength: maxLength, level: 0.004)
            // While the other side talks, what is only the call coming back through the microphone stays out of Whisper.
            micPieces = EchoLeak.keeping(micPieces, mic: micTrack, reference: input.samples)
        }
        let total = max(1, (pieces + micPieces).reduce(0) { $0 + $1.end - $1.start })
        var done = 0.0

        guard let whisper = await onWhisperQueue({ Whisper.cached(input.model) }) else {
            throw BatchFailure.model(input.model.lastPathComponent)
        }
        var segments: [Segment] = []
        var lastLanguage: [String: String] = [:]
        for (list, samples, mic) in [(pieces, input.samples, false), (micPieces, micTrack ?? [], true)] {
            for piece in list {
                try Task.checkCancellation()
                await input.pause()
                let a = max(0, Int(piece.start * Chunker.rate)), b = min(samples.count, Int(piece.end * Chunker.rate))
                guard a < b else { continue }
                var audio = Array(samples[a..<b])
                // whisper.cpp skips anything under a second.
                if audio.count < 17_600 { audio += [Float](repeating: 0, count: 17_600 - audio.count) }
                let clip = audio
                var language = input.language
                if language == "auto" {
                    // A short piece says too little to tell: keep the language this voice spoke last.
                    let key = mic ? "mic" : piece.voice ?? ""
                    let detected = piece.end - piece.start >= 2.5 ? await onWhisperQueue { whisper.language(of: clip) } : nil
                    if let detected, detected.probability >= 0.5 || lastLanguage[key] == nil { language = detected.code }
                    else { language = lastLanguage[key] ?? detected?.code ?? "auto" }
                    lastLanguage[key] = language
                }
                let spoken = language
                let lines = await onWhisperQueue { whisper.transcribe(clip, language: spoken) }
                for line in lines where !StreamingTranscriber.isNoise(line.text) {
                    let la = Int(line.start * Chunker.rate), lb = min(clip.count, Int(line.end * Chunker.rate))
                    guard la < lb, Chunker.rms(clip[la..<lb]) > 0.001 else { continue }
                    segments.append(Segment(start: piece.start + line.start, end: min(piece.end, piece.start + line.end),
                                            speaker: mic ? Microphone.speakerName : nil, text: line.text, mic: mic ? true : nil))
                }
                done += piece.end - piece.start
                progress(0.1 + 0.9 * done / total)
            }
        }
        segments.sort { $0.start < $1.start }
        segments = EchoLines.dropping(segments)
        if !turns.isEmpty {
            segments = Voices.label(segments, turns: turns, marks: input.marks)
        } else if !input.marks.isEmpty {
            let timeline = SpeakerTimeline(input.marks)
            for i in segments.indices where segments[i].mic != true {
                segments[i].speaker = timeline.speaker(from: segments[i].start, to: segments[i].end)
            }
        }
        return StreamingTranscriber.droppingLoops(segments)
    }

    /// Voices for a session transcribed live: the lines stay, only who said them changes.
    static func relabel(_ segments: [Segment], samples: [Float], marks: [NameMark], progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        let turns = try await VoiceSeparator.shared.turns(samples, progress: progress)
        return Voices.label(segments, turns: turns, marks: marks)
    }

    /// Runs on the queue every Whisper call goes through, so a live session and a batch job never use the model at once.
    private static func onWhisperQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            StreamingTranscriber.queue.async { continuation.resume(returning: work()) }
        }
    }
}

enum BatchFailure: LocalizedError {
    case model(String)
    case noModel
    case missingAudio
    var errorDescription: String? {
        switch self {
        case let .model(name): String(localized: "Could not load the model \(name).")
        case .noModel: String(localized: "No Whisper model found. Put a ggml model in ~/Library/Application Support/Earshot/Models.")
        case .missingAudio: String(localized: "The audio of this session is missing.")
        }
    }
}
