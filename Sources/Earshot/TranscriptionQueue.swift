import Foundation
import UserNotifications

/// Work done once the audio is saved, one job at a time: transcribing a session recorded with
/// "After the call" or an imported file, or telling the voices apart in a session transcribed live.
@Observable @MainActor
final class TranscriptionQueue {
    enum Kind: Equatable {
        /// Whole transcript from the saved audio (and the source file first, for an import).
        case transcribe
        /// Only who said each line, for a session already transcribed live.
        case voices
        /// Only Summary.txt, for a session that already has its transcript.
        case summary
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let folder: URL
        let kind: Kind
        let title: String
    }

    /// The first job is the one running.
    private(set) var jobs: [Job] = []
    /// 0...1, for the running job.
    private(set) var progress: Double = 0
    /// True while the work waits for a recording to end.
    private(set) var paused = false
    /// True while the running job writes its summary (after a transcript, or on its own).
    private(set) var summarizing = false
    /// Whether to hold the work for now: during a recording, nothing heavy runs (the point of "After the call").
    var hold: () -> Bool = { false }
    var onFinished: (URL) -> Void = { _ in }
    private var worker: Task<Void, Never>?

    var current: Job? { jobs.first }

    func add(_ folder: URL, kind: Kind, title: String) {
        guard !jobs.contains(where: { Self.same($0.folder, folder) }) else { return }
        jobs.append(Job(folder: folder, kind: kind, title: title))
        if worker == nil { worker = Task { await drain() } }
    }

    /// Whether a session waits or is being worked on, and how far along: nil when nothing is queued for it.
    func status(of folder: URL?) -> (waiting: Bool, kind: Kind, progress: Double)? {
        guard let folder, let i = jobs.firstIndex(where: { Self.same($0.folder, folder) }) else { return nil }
        return (i > 0, i == 0 && summarizing ? .summary : jobs[i].kind, i == 0 ? progress : 0)
    }

    /// What the running job is doing now: its own kind, or `.summary` once its transcript is done.
    var currentKind: Kind? { current.map { summarizing ? .summary : $0.kind }
    }

    static func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path }

    private func drain() async {
        while let job = jobs.first {
            progress = 0
            await waitWhileHeld()
            await run(job)
            jobs.removeFirst()
            onFinished(job.folder)
        }
        worker = nil
    }

    /// Returns once no recording is running; checked before each job and between the pieces of a transcript.
    func waitWhileHeld() async {
        while hold() {
            paused = true
            try? await Task.sleep(for: .seconds(2))
        }
        paused = false
    }

    private func run(_ job: Job) async {
        guard var record = SessionStore.load(job.folder) else { return }
        let defaults = UserDefaults.standard
        let report: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor in self?.progress = max(self?.progress ?? 0, value) } }
        let audio = job.folder.appending(path: SessionStore.audioName)
        let appTrack = job.folder.appending(path: SessionStore.appTrackName)
        let micTrack = job.folder.appending(path: SessionStore.micTrackName)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        do {
            // A recording Earshot could not close (forced quit, crash) still has its raw sound: encode it first.
            let folder = job.folder
            try await Task.detached { try SessionStore.finalizeAudio(in: folder) }.value
            switch job.kind {
            case .summary:
                break
            case .voices:
                guard defaults.object(forKey: Pref.separateVoices) as? Bool ?? true else { break }
                await waitWhileHeld()
                let samples = exists(appTrack) ? try RawTrack.read(appTrack) : try await AudioFile.samples(audio)
                record.segments = try await BatchTranscriber.relabel(record.segments, samples: samples, marks: record.names ?? [], progress: report)
            case .transcribe:
                guard let model = WhisperModel.preferred(defaults.string(forKey: Pref.model) ?? "") else { throw BatchFailure.noModel }
                let samples: [Float]
                if exists(appTrack) {
                    samples = try RawTrack.read(appTrack)
                } else if exists(audio) {
                    samples = try await AudioFile.samples(audio)
                } else if let source = record.source, exists(URL(filePath: source)) {
                    samples = try await AudioFile.samples(URL(filePath: source))
                    try AudioFile.write(samples, to: audio)
                    record.duration = Double(samples.count) / Chunker.rate
                    SessionStore.write(record, to: job.folder)
                } else {
                    throw BatchFailure.missingAudio
                }
                var mic: [Float]?
                if exists(micTrack) { mic = try RawTrack.read(micTrack) }
                let input = BatchTranscriber.Input(
                    samples: samples, mic: mic, marks: record.names ?? [],
                    language: defaults.string(forKey: Pref.language) ?? "auto",
                    separateVoices: defaults.object(forKey: Pref.separateVoices) as? Bool ?? true,
                    model: model.url,
                    pause: { [weak self] in await self?.waitWhileHeld() })
                record.segments = try await BatchTranscriber.run(input, progress: report)
                notify(record)
            }
            if job.kind != .summary {
                record.status = nil
                record.failure = nil
                // The separate tracks only served to tell the user's voice from the call's.
                if !defaults.bool(forKey: Pref.keepTracks) {
                    try? FileManager.default.removeItem(at: appTrack)
                    try? FileManager.default.removeItem(at: micTrack)
                }
                SessionStore.write(record, to: job.folder)
                onFinished(job.folder)  // the transcript shows now, while its summary is written
            }
            // Asked for (Summarize again) or on by default after each transcript.
            if job.kind == .summary || defaults.object(forKey: Pref.summarize) as? Bool ?? true {
                await summarize(record, in: job.folder)
            }
            return
        } catch {
            // Telling voices apart is a bonus: when it fails, the live transcript stays as it was.
            if job.kind == .transcribe {
                record.status = .failed
                record.failure = error.localizedDescription
            }
        }
        SessionStore.write(record, to: job.folder)
    }

    /// Summary.txt with Apple's on-device model. A failure leaves the transcript as it is: the summary is a bonus.
    private func summarize(_ record: SessionRecord, in folder: URL) async {
        guard CallSummarizer.isAvailable, !record.segments.isEmpty else { return }
        await waitWhileHeld()
        summarizing = true
        progress = 0
        defer { summarizing = false }
        let report: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor in self?.progress = max(self?.progress ?? 0, value) } }
        do {
            if let text = try await CallSummarizer.summarize(record, progress: report) {
                try text.write(to: Summary.url(in: folder), atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: Summary.url(in: folder))  // too short now: an old summary would be wrong
            }
        } catch {
            // Kept as it was: an older summary stays rather than none.
        }
    }

    private func notify(_ record: SessionRecord) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Transcript ready")
        content.body = record.title
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
        }
    }
}
