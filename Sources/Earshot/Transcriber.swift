import Foundation
import whisper

/// whisper.cpp model file found on disk.
struct WhisperModel: Hashable, Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
    }

    /// Folders where ggml models usually live (whisper-cpp cache, BetterDictation, our own).
    static let searchFolders: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Application Support/Earshot/Models"),
            home.appending(path: ".cache/whisper-cpp"),
            home.appending(path: "Library/Application Support/com.stoti.BetterDictation/Models"),
        ]
    }()

    static func installed() -> [WhisperModel] {
        var seen = Set<String>()
        return searchFolders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        .filter { seen.insert($0.lastPathComponent).inserted }
        .map(WhisperModel.init)
    }

    /// large-v3-turbo first: near large-v3 quality at a fraction of the cost, which keeps the live text snappy.
    static func preferred(_ path: String) -> WhisperModel? {
        let all = installed()
        return all.first { $0.url.path == path }
            ?? all.first { $0.name == "large-v3-turbo" }
            ?? all.first { $0.name.hasPrefix("large-v3") }
            ?? all.first
    }
}

/// Thin wrapper over a whisper.cpp context. Not thread-safe: use from one queue.
final class Whisper {
    private let ctx: OpaquePointer

    init?(model: URL) {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(model.path, params) else { return nil }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Loading takes a few seconds, so the last model stays in memory between sessions.
    private static var cache: (url: URL, whisper: Whisper)?
    private static let cacheLock = NSLock()
    static func cached(_ url: URL) -> Whisper? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache, cache.url == url { return cache.whisper }
        cache = nil
        guard let w = Whisper(model: url) else { return nil }
        cache = (url, w)
        return w
    }

    /// Segments with times relative to the start of `samples` (16 kHz mono).
    func transcribe(_ samples: [Float], language: String, quick: Bool = false) -> [(start: Double, end: Double, text: String)] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.no_context = true          // a prompt from the previous block caused repetitions in the prototype
        params.single_segment = quick
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_nst = true
        if quick { params.temperature_inc = 0 } // no fallback passes for the preview line
        let n = language.withCString { lang -> Int32 in
            params.language = lang
            return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        }
        guard n == 0 else { return [] }
        return (0..<whisper_full_n_segments(ctx)).compactMap { i in
            let text = String(cString: whisper_full_get_segment_text(ctx, i)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (Double(whisper_full_get_segment_t0(ctx, i)) / 100, Double(whisper_full_get_segment_t1(ctx, i)) / 100, text)
        }
    }
}

/// Turns a continuous 16 kHz stream into committed segments plus a live "being spoken" line.
///
/// Audio accumulates in a pending block. The block is committed (transcribed for good) at a pause in
/// speech, or at 25 s in the quietest spot. Between commits the pending block is re-transcribed about
/// once a second for the live line. Blocks with no speech are dropped: silence makes Whisper hallucinate.
final class StreamingTranscriber {
    static let rate = 16_000.0
    /// RMS above this counts as speech. Call audio is clean, so a fixed level is enough.
    var speechLevel: Float = 0.004

    private var whisper: Whisper?
    private let language: String
    private let queue = DispatchQueue(label: "earshot.whisper", qos: .userInitiated)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var pending: [Float] = []
    private var pendingStart: Double = 0
    private var trailingSilence: Double = 0
    private var heardSpeech = false
    private var busy = false
    private var lastPreview = Date.distantPast
    private var lastLevel = Date.distantPast

    var onCommit: ([Segment]) -> Void = { _ in }
    var onPreview: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    /// The model loads on the transcription queue, so capture starts right away and nothing is lost meanwhile.
    init(model: URL, language: String) {
        self.language = language
        queue.async { [self] in
            whisper = Whisper.cached(model)
            if whisper == nil { onError("Could not load the model \(model.lastPathComponent).") }
        }
    }

    /// Called from the audio thread with 16 kHz samples.
    func append(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        lock.lock()
        if Date().timeIntervalSince(lastLevel) > 0.1 { lastLevel = Date(); onLevel(rms) }  // 10 Hz is plenty for a meter
        pending += samples
        let seconds = Double(samples.count) / Self.rate
        if rms > speechLevel { heardSpeech = true; trailingSilence = 0 } else { trailingSilence += seconds }
        let duration = Double(pending.count) / Self.rate
        let action: Action
        if busy {
            action = .none
        } else if !heardSpeech && duration > 2 {
            pendingStart += duration; pending = []; trailingSilence = 0  // nothing said: drop it
            action = .none
        } else if heardSpeech && ((duration > 3 && trailingSilence > 0.6) || duration > 25) {
            let cut = duration > 25 && trailingSilence < 0.3 ? quietestCut() : pending.count
            let block = Array(pending[..<cut]); let start = pendingStart
            pending.removeFirst(cut); pendingStart += Double(cut) / Self.rate
            heardSpeech = rmsOf(pending) > speechLevel; trailingSilence = 0
            busy = true; action = .commit(block, start)
        } else if heardSpeech && Date().timeIntervalSince(lastPreview) > 1 {
            busy = true; lastPreview = Date(); action = .preview(pending)
        } else {
            action = .none
        }
        lock.unlock()
        run(action)
    }

    /// Commits what is left, then calls `done` on the transcription queue.
    func finish(_ done: @escaping () -> Void) {
        queue.async { [self] in
            lock.lock()
            let block = pending, start = pendingStart, speech = heardSpeech
            pending = []; heardSpeech = false
            lock.unlock()
            if speech { commit(block, start) }
            done()
        }
    }

    private enum Action { case none, commit([Float], Double), preview([Float]) }

    private func run(_ action: Action) {
        switch action {
        case .none: return
        case let .commit(block, start):
            queue.async { [self] in commit(block, start); setIdle() }
        case let .preview(block):
            queue.async { [self] in
                let text = (whisper?.transcribe(block, language: language, quick: true) ?? []).map(\.text).joined(separator: " ")
                if !Self.isNoise(text) { onPreview(text) }
                setIdle()
            }
        }
    }

    private func commit(_ block: [Float], _ start: Double) {
        let segments = (whisper?.transcribe(block, language: language) ?? []).compactMap { s -> Segment? in
            let a = Int(s.start * Self.rate), b = min(block.count, Int(s.end * Self.rate))
            // Drop lines over near-silent audio, and Whisper's stock hallucinations.
            guard !Self.isNoise(s.text), b > a, rmsOf(Array(block[a..<b])) > speechLevel / 2 else { return nil }
            return Segment(start: start + s.start, end: start + s.end, text: s.text)
        }
        onPreview("")
        if !segments.isEmpty { onCommit(segments) }
    }

    private func setIdle() { lock.lock(); busy = false; lock.unlock() }

    /// Quietest 100 ms window in the last 5 s of the pending block (call with `lock` held).
    private func quietestCut() -> Int {
        let window = Int(Self.rate / 10)
        var best = pending.count, bestRMS = Float.greatestFiniteMagnitude
        var i = max(0, pending.count - Int(Self.rate * 5))
        while i + window <= pending.count {
            let r = rmsOf(Array(pending[i..<i + window]))
            if r < bestRMS { bestRMS = r; best = i + window / 2 }
            i += window
        }
        return best
    }

    private func rmsOf(_ s: [Float]) -> Float { s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count)) }

    static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if t.isEmpty || text.hasPrefix("[") || text.hasPrefix("(") || text.hasPrefix("*") { return true }
        return ["you", "thanks for watching", "thank you for watching", "subtitles by the amara.org community", "sous-titres réalisés par la communauté d'amara.org"].contains(t)
    }
}
