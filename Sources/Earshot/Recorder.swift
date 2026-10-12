import AVFoundation
import EventKit
import SwiftUI

/// Settings keys, shared by the views and the recorder.
enum Pref {
    static let language = "language"        // "auto", "en", "fr"
    static let model = "modelPath"
    static let folder = "saveFolder"
    static let autoCaptions = "autoCaptions"
    static let includeMic = "includeMic"
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Earshot").path
}

/// One recording: capture, live transcription, speaker names, auto-stop and saving.
@Observable @MainActor
final class Recorder {
    enum State { case idle, recording, finishing }

    var state = State.idle
    var app: AudioApp?
    var title = ""
    var startedAt = Date()
    var segments: [Segment] = []
    var preview = ""
    var previewSpeaker: String?
    var level: Float = 0
    var eventEnd: Date?
    var folder: URL?
    var error: String?
    var needsAccessibility = false
    var onFinished: (SessionRecord) -> Void = { _ in }

    private var tap: AudioTap?
    private var transcriber: StreamingTranscriber?
    private var captions: TeamsCaptions?
    private var microphone: Microphone?
    private var micTranscriber: StreamingTranscriber?
    private var timeline = SpeakerTimeline()
    private var audioFile: AVAudioFile?
    private var watchdog: Timer?
    private var lastSound = Date()
    private var record: SessionRecord?

    var isActive: Bool { state != .idle }
    var includesMic: Bool { microphone != nil }
    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    func start(_ app: AudioApp) async {
        guard state == .idle else { return }
        let defaults = UserDefaults.standard
        guard let model = WhisperModel.preferred(defaults.string(forKey: Pref.model) ?? "") else {
            error = String(localized: "No Whisper model found. Put a ggml model in ~/Library/Application Support/Earshot/Models.")
            return
        }
        error = nil
        let event = await CalendarLookup.currentEvent()
        let base = URL(filePath: defaults.string(forKey: Pref.folder) ?? Pref.defaultFolder)
        let group = event.map { CalendarLookup.courseName($0.title) } ?? app.name
        let folder = SessionStore.newFolder(base: base, group: group)

        self.app = app
        title = event?.title ?? "\(app.name) call"
        eventEnd = event?.end
        startedAt = Date()
        segments = []
        preview = ""
        timeline = SpeakerTimeline()
        lastSound = Date()
        self.folder = folder
        record = SessionRecord(title: title, appName: app.name, bundleID: app.bundleID, startedAt: startedAt, duration: 0, segments: [])

        let language = defaults.string(forKey: Pref.language) ?? "auto"
        let transcriber = StreamingTranscriber(model: model.url, language: language)
        transcriber.onCommit = { [weak self] segs in Task { @MainActor in self?.commit(segs) } }
        transcriber.onPreview = { [weak self] text in Task { @MainActor in self?.preview = text; self?.previewSpeaker = self?.timeline.latest } }
        transcriber.onLevel = { [weak self] rms in Task { @MainActor in self?.level = rms } }
        transcriber.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        self.transcriber = transcriber

        var mix: MicMix?
        if defaults.bool(forKey: Pref.includeMic) {
            if await Microphone.requestAccess() {
                mix = MicMix()
                let micTranscriber = StreamingTranscriber(model: model.url, language: language)
                micTranscriber.onCommit = { [weak self] segs in
                    Task { @MainActor in self?.commit(segs.map { s in var s = s; s.speaker = Microphone.speakerName; s.mic = true; return s }) }
                }
                self.micTranscriber = micTranscriber
            } else {
                error = Microphone.Failure.denied.localizedDescription
            }
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            audioFile = try AVAudioFile(forWriting: folder.appending(path: "Audio.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let file = audioFile
            tap = try AudioTap(processes: app.processes) { samples in
                transcriber.append(samples)
                let samples = mix?.mixApp(samples) ?? samples
                guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                try? file.write(from: buffer)
            }
            if let mix, let micTranscriber {
                microphone = try Microphone { samples in micTranscriber.append(mix.gateMic(samples)) }
            }
        } catch {
            self.error = error.localizedDescription
            cleanUp()
            return
        }

        if TeamsCaptions.handles(app.bundleID) { startCaptions(pid: app.pid) }
        state = .recording
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
        save()
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        tap?.stop()
        tap = nil
        microphone?.stop()
        microphone = nil
        watchdog?.invalidate()
        guard let transcriber else { cleanUp(); return }
        let micTranscriber = micTranscriber
        let finishMic: (@escaping () -> Void) -> Void = { done in if let micTranscriber { micTranscriber.finish(done) } else { done() } }
        transcriber.finish {
            finishMic { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.captions?.stop()
                    self.attributeSpeakers(since: 0)
                    self.audioFile = nil  // closes the m4a
                    self.save()
                    if let record = self.record { self.onFinished(record) }
                    self.cleanUp()
                }
            }
        }
    }

    func retryAccessibility() {
        TeamsCaptions.requestTrust()
        if let app, TeamsCaptions.isTrusted { startCaptions(pid: app.pid) }
    }

    private func startCaptions(pid: pid_t) {
        guard TeamsCaptions.isTrusted else { needsAccessibility = true; TeamsCaptions.requestTrust(); return }
        needsAccessibility = false
        captions?.stop()
        let captions = TeamsCaptions(pid: pid)
        captions.onSpeaker = { [weak self] date, name in
            Task { @MainActor in
                guard let self else { return }
                self.timeline.add(date.timeIntervalSince(self.startedAt), name)
                if !self.preview.isEmpty { self.previewSpeaker = name }
            }
        }
        if UserDefaults.standard.object(forKey: Pref.autoCaptions) as? Bool ?? true { captions.turnOnCaptions() }
        captions.start()
        self.captions = captions
    }

    private func commit(_ new: [Segment]) {
        segments += new
        if new.contains(where: { $0.mic == true }) { segments.sort { $0.start < $1.start } }
        // Captions trail the audio, so the last few lines get a second look once more captions are in.
        attributeSpeakers(since: (new.first?.start ?? 0) - 30)
        save()
    }

    private func attributeSpeakers(since time: TimeInterval) {
        for i in segments.indices.reversed() where segments[i].mic != true {
            guard segments[i].end >= time else { break }
            segments[i].speaker = timeline.speaker(from: segments[i].start, to: segments[i].end) ?? segments[i].speaker
        }
    }

    /// Stops when the app quits, or when it has been silent for a while once the calendar event is over.
    /// Teams keeps its audio running for the whole call, so a class break does not count as silence.
    private func check() {
        guard state == .recording, let app else { return }
        guard let fresh = app.refreshed() else { stop(); return }
        if fresh.processes != self.app?.processes { tap?.update(processes: fresh.processes); self.app = fresh }
        if fresh.isPlaying { lastSound = Date() }
        let quiet = Date().timeIntervalSince(lastSound)
        if let end = eventEnd { if Date() > end && quiet > 120 { stop() } } else if quiet > 180 { stop() }
        if captions == nil, needsAccessibility, TeamsCaptions.isTrusted { startCaptions(pid: app.pid) }
    }

    /// Written after every new line, so a crash loses at most a few seconds of text.
    private func save() {
        guard var record, let folder else { return }
        record.segments = segments
        record.duration = elapsed
        self.record = record
        SessionStore.write(record, to: folder)
    }

    private func cleanUp() {
        tap?.stop(); tap = nil
        microphone?.stop(); microphone = nil
        captions?.stop(); captions = nil
        transcriber = nil
        micTranscriber = nil
        audioFile = nil
        watchdog?.invalidate(); watchdog = nil
        state = .idle
        preview = ""
        level = 0
    }
}

// MARK: - Calendar

enum CalendarLookup {
    private static let store = EKEventStore()

    /// The event happening now (or starting within 30 min). `end` is the end of that event's last slot today,
    /// so a class split around a lunch break still counts as one session.
    static func currentEvent() async -> (title: String, end: Date)? {
        if CommandLine.arguments.contains("--no-calendar") { return nil }
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let events = store.events(matching: store.predicateForEvents(withStart: dayStart, end: dayStart.addingTimeInterval(86_400), calendars: nil))
            .filter { !$0.isAllDay }
        guard let current = events.first(where: { $0.startDate <= now.addingTimeInterval(1800) && $0.endDate >= now }) else { return nil }
        let end = events.filter { $0.title == current.title }.map(\.endDate).max() ?? current.endDate!
        return (current.title, end)
    }

    /// "SCHOOL : Course name - Session 3" -> "Course name"
    static func courseName(_ title: String) -> String {
        var name = title
        if let r = name.range(of: " : ") { name = String(name[r.upperBound...]) }
        if let r = name.range(of: " - ") { name = String(name[..<r.lowerBound]) }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Files

enum SessionStore {
    static let recordName = ".earshot.json"

    /// <base>/<group>/<yyyy-MM-dd>, with " 2", " 3"... for further sessions the same day.
    static func newFolder(base: URL, group: String) -> URL {
        let day = Date().formatted(.iso8601.year().month().day())
        let parent = base.appending(path: group.replacingOccurrences(of: "/", with: "-"))
        var folder = parent.appending(path: day)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = parent.appending(path: "\(day) \(n)"); n += 1 }
        return folder
    }

    static func write(_ r: SessionRecord, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(r).write(to: folder.appending(path: recordName), options: .atomic)
        try? text(r).write(to: folder.appending(path: "Transcript.txt"), atomically: true, encoding: .utf8)
        try? markdown(r).write(to: folder.appending(path: "Transcript.md"), atomically: true, encoding: .utf8)
        try? srt(r).write(to: folder.appending(path: "Transcript.srt"), atomically: true, encoding: .utf8)
    }

    static func loadAll(base: URL) -> [SessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { item -> SessionRecord? in
            guard let url = item as? URL, url.lastPathComponent == recordName,
                  let data = try? Data(contentsOf: url), var r = try? decoder.decode(SessionRecord.self, from: data) else { return nil }
            r.folder = url.deletingLastPathComponent()
            return r
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private static func wallClock(_ r: SessionRecord, _ t: TimeInterval) -> String {
        r.startedAt.addingTimeInterval(t).formatted(date: .omitted, time: .standard)
    }

    static func text(_ r: SessionRecord) -> String {
        var out = "\(r.title) — \(r.startedAt.formatted(date: .long, time: .shortened))\n"
        for t in Turn.group(r.segments) {
            out += "\n[\(wallClock(r, t.start))]" + (t.speaker.map { " \($0)" } ?? "") + "\n\(t.text)\n"
        }
        return out
    }

    static func markdown(_ r: SessionRecord) -> String {
        var out = "# \(r.title)\n\n*\(r.appName) · \(r.startedAt.formatted(date: .long, time: .shortened)) · \(r.duration.spoken)*\n"
        for t in Turn.group(r.segments) {
            out += "\n**\(t.speaker ?? "Unknown")** · \(wallClock(r, t.start))\n\n\(t.text)\n"
        }
        return out
    }

    static func srt(_ r: SessionRecord) -> String {
        func stamp(_ t: TimeInterval) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return r.segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start)) --> \(stamp(s.end))\n" + (s.speaker.map { "\($0): " } ?? "") + s.text + "\n"
        }.joined(separator: "\n")
    }
}
