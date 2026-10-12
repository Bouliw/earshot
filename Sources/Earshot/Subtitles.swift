import AVFoundation
import Speech
import SwiftUI

// Live subtitles: the last two lines said in the app being transcribed, from a streaming engine that runs
// next to Whisper (Whisper still writes the saved transcript).

enum SubtitleEngineKind: String { case apple, kyutai }

protocol SubtitleEngine: AnyObject {
    /// 16 kHz mono samples, from the audio thread.
    func append(_ samples: [Float])
    func stop()
}

/// What the subtitle window shows: the last phrases, the final one possibly still being said.
@Observable @MainActor
final class SubtitleFeed {
    struct Line: Equatable { var speaker: String?; var text: String }

    private(set) var lines: [Line] = []
    /// Lines started since the last `clear()`, including those no longer kept.
    private(set) var total = 0
    var error: String?
    /// Who is speaking right now, when the app tells (Teams captions).
    var speaker: () -> String? = { nil }
    private var open = false

    /// Replaces the phrase being said (or starts a new one).
    func update(_ text: String) {
        let text = String(text.drop(while: \.isWhitespace))  // a trailing space can be a word break still to come
        guard !text.isEmpty else { return }
        if open { lines[lines.count - 1].text = text } else { lines.append(Line(speaker: speaker(), text: text)); open = true; total += 1 }
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
    }

    func commit() { open = false }

    /// Adds a piece of text to the phrase being said; punctuation or a new speaker ends the phrase.
    func append(_ piece: String) {
        if open, let now = speaker(), now != lines.last?.speaker { commit() }
        update((open ? lines[lines.count - 1].text : "") + piece)
        if let last = piece.last, ".?!".contains(last) { commit() }
    }

    func clear() { lines = []; total = 0; open = false; error = nil }
}

/// The running engine, reachable from the audio thread.
final class SubtitleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: SubtitleEngine?

    func append(_ samples: [Float]) {
        lock.lock(); let engine = engine; lock.unlock()
        engine?.append(samples)
    }

    /// Puts `new` in place and returns the previous engine.
    @discardableResult func swap(_ new: SubtitleEngine?) -> SubtitleEngine? {
        lock.lock(); defer { lock.unlock() }
        let old = engine
        engine = new
        return old
    }
}

enum SubtitleFailure: LocalizedError {
    case language, notInstalled, stopped(String)
    var errorDescription: String? {
        switch self {
        case .language: String(localized: "This language is not installed on this Mac for Fast subtitles. Pick High, or another spoken language.")
        case .notInstalled: String(localized: "High subtitles are not installed. Install them in Settings.")
        case let .stopped(detail): String(localized: "High subtitles stopped: \(detail)")
        }
    }
}

// MARK: - Fast: Apple's SpeechAnalyzer

/// Apple's on-device recognizer. It only uses languages macOS already has, so it never downloads anything.
final class AppleSubtitles: SubtitleEngine {
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let resample: Resampler?

    init(language: String, feed: SubtitleFeed) async throws {
        guard let locale = await Self.locale(for: language) else { throw SubtitleFailure.language }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw SubtitleFailure.language }
        resample = Resampler(from: Resampler.format, to: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
        Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run { feed.update(text); if result.isFinal { feed.commit() } }
                }
            } catch {
                await MainActor.run { feed.error = error.localizedDescription }
            }
        }
    }

    /// The spoken language if macOS has it installed ("auto": the system language, else English).
    static func locale(for language: String) async -> Locale? {
        let installed = await SpeechTranscriber.installedLocales
        let system = Locale.current.language.languageCode?.identifier ?? "en"
        for code in language == "auto" ? [system, "en"] : [language] {
            let matches = installed.filter { $0.language.languageCode?.identifier == code }
            if let best = matches.first(where: { $0.region == Locale.current.region }) ?? matches.first(where: { $0.identifier == (code == "fr" ? "fr_FR" : "en_US") }) ?? matches.first {
                return best
            }
        }
        return nil
    }

    func append(_ samples: [Float]) {
        guard let buffer = Resampler.buffer(samples), let converted = resample?.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        input.finish()
        let analyzer = analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }
}

// MARK: - High: Kyutai STT on MLX

/// Kyutai STT 1B en_fr, run by `kyutai-stt.py` in the engine's own Python environment.
final class KyutaiSubtitles: SubtitleEngine {
    private let process = Process()
    private let stdin = Pipe()
    private let resample = Resampler(from: Resampler.format, to: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
    private let writer = DispatchQueue(label: "earshot.kyutai")
    private let lock = NSLock()
    private var queued = 0  // bytes waiting for the pipe, guarded by `lock`
    private var ready = false  // model loaded, guarded by `lock`
    private var stopping = false

    init(feed: SubtitleFeed) throws {
        guard Kyutai.isInstalled, let script = Bundle.main.url(forResource: "kyutai-stt", withExtension: "py") else { throw SubtitleFailure.notInstalled }
        signal(SIGPIPE, SIG_IGN)  // if the engine dies, writing to it must fail, not end the app
        process.executableURL = Kyutai.folder.appending(path: "venv/bin/python")
        process.arguments = ["-I", script.path, Kyutai.folder.appending(path: "model").path]
        process.standardInput = stdin
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var pending = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            pending.append(handle.availableData)
            var pieces: [String] = []
            while let newline = pending.firstIndex(of: 10) {
                pieces.append(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
            if pieces.contains("") { self?.lock.withLock { self?.ready = true } }
            pieces.removeAll { $0.isEmpty }
            guard !pieces.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { pieces.forEach(feed.append) } }  // in order
        }
        var log = ""
        err.fileHandleForReading.readabilityHandler = { handle in log = String((log + String(decoding: handle.availableData, as: UTF8.self)).suffix(2000)) }
        process.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard self?.stopping == false else { return }
            let detail = log.split(separator: "\n").last.map(String.init) ?? "exit"
            Task { @MainActor in feed.error = SubtitleFailure.stopped(detail).localizedDescription }
        }
        try process.run()
    }

    func append(_ samples: [Float]) {
        guard let buffer = Resampler.buffer(samples), let out = resample?.convert(buffer), let data = out.floatChannelData else { return }
        let bytes = Data(bytes: data[0], count: Int(out.frameLength) * MemoryLayout<Float>.size)
        lock.lock()
        let late = !ready || queued > 24_000 * 4  // loading, or 1 s behind: drop, subtitles are only useful live
        if !late { queued += bytes.count }
        lock.unlock()
        guard !late else { return }
        writer.async { [self] in
            try? stdin.fileHandleForWriting.write(contentsOf: bytes)
            lock.lock(); queued -= bytes.count; lock.unlock()
        }
    }

    func stop() {
        stopping = true
        process.terminate()
        writer.async { [stdin] in try? stdin.fileHandleForWriting.close() }
    }
}

/// The High engine's files (a Python environment and the model), installed on demand in Application Support.
@Observable @MainActor
final class Kyutai {
    enum State: Equatable { case missing, installing(Double), installed, failed(String) }

    static let shared = Kyutai()
    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Earshot/Kyutai")
    private static let modelBytes = 2_363_190_187.0
    /// Model plus Python packages.
    static let size = ByteCountFormatter.string(fromByteCount: 2_409_000_000, countStyle: .file)
    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: folder.appending(path: ".installed").path) }

    var state: State = isInstalled ? .installed : .missing
    private var process: Process?

    func install() {
        guard process == nil, let script = Bundle.main.url(forResource: "install-kyutai", withExtension: "sh") else { return }
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = [script.path, Self.folder.path]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        var log = ""
        err.fileHandleForReading.readabilityHandler = { handle in log = String((log + String(decoding: handle.availableData, as: UTF8.self)).suffix(2000)) }
        p.terminationHandler = { p in
            err.fileHandleForReading.readabilityHandler = nil
            let ok = p.terminationStatus == 0 && Self.isInstalled
            let detail = log.split(separator: "\n").last.map(String.init) ?? ""
            Task { @MainActor in
                self.process = nil
                if ok { UserDefaults.standard.set(SubtitleEngineKind.kyutai.rawValue, forKey: Pref.subtitleEngine) }
                self.state = ok ? .installed : p.terminationReason == .uncaughtSignal ? .missing : .failed(detail)
            }
        }
        do { try p.run() } catch { state = .failed(error.localizedDescription); return }
        process = p
        state = .installing(0)
        Task {
            while case .installing = state {
                state = .installing(min(1, Self.downloaded() / Self.modelBytes))
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    /// Stops a download in progress; what is already there is kept and resumed next time.
    func cancel() { process?.terminate() }

    private static func downloaded() -> Double {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "model"), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Double((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - Window

/// Small translucent window with the last two lines, movable by dragging it anywhere.
struct SubtitlesView: View {
    @Environment(AppState.self) private var state
    @AppStorage(Pref.subtitleSize) private var size = 24.0
    @AppStorage(Pref.subtitles) private var enabled = false
    @ViewState private var hover = false

    var body: some View {
        let feed = state.recorder.subtitles
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size, weight: .medium))
        Group {
            if feed.lines.isEmpty {
                Text(feed.error ?? String(localized: "Listening…")).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            } else {
                // Taller than two lines when it wraps more: the frame below keeps the bottom two.
                Text(Self.render(feed.lines, size: size)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: size, weight: .medium))
        .frame(width: min(1100, max(420, size * 26)), height: ceil(lineHeight * 2), alignment: .bottomLeading)
        .clipped()
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hover {
                HStack(spacing: 4) {
                    control("textformat.size.smaller", "Smaller text") { size = max(14, size - 2) }
                    control("textformat.size.larger", "Larger text") { size = min(48, size + 2) }
                    control("xmark", "Turn off live subtitles") { enabled = false }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .containerBackground(.clear, for: .window)
    }

    private func control(_ icon: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(.white.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One paragraph per speaker turn, with the name in front when it is known.
    static func render(_ lines: [SubtitleFeed.Line], size: Double) -> AttributedString {
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            let newTurn = i == 0 || line.speaker != lines[i - 1].speaker
            if i > 0 { out += AttributedString(newTurn ? "\n" : " ") }
            if newTurn, let name = line.speaker {
                var label = AttributedString(name + "  ")
                label.foregroundColor = SpeakerColor.of(name)
                label.font = .system(size: size * 0.8, weight: .bold)
                out += label
            }
            out += AttributedString(line.text)
        }
        return out
    }
}
