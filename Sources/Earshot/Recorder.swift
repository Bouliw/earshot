import AVFoundation
import EventKit
import SwiftUI

/// Settings keys, shared by the views and the recorder.
enum Pref {
    static let language = "language"        // "auto", "en", "fr"
    static let model = "modelPath"
    static let folder = "saveFolder"
    static let callsFolder = "callsFolder"   // "": the same folder as classes
    static let autoCaptions = "autoCaptions"
    static let includeMic = "includeMic"
    static let micDevice = "micDevice"      // UID of the input to record; "": the Mac's default input
    static let subtitles = "subtitles"
    static let subtitleEngine = "subtitleEngine"  // SubtitleEngineKind
    static let subtitleSize = "subtitleSize"
    static let mode = "transcriptionMode"   // TranscriptionMode
    static let separateVoices = "separateVoices"
    static let summarize = "summarizeCalls"     // Summary.txt after each transcript (on unless turned off)
    static let indexTranscripts = "indexTranscripts"
    static let indexer = "docIndexerScript"   // path to doc-indexer's extract_texts.py ("": found by itself)
    static let indexFolder = "indexFolder"    // "": the folder sessions are saved to
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Earshot").path

    /// Every folder sessions are saved to: the "Save to" folder, and the calls folder when it is another one.
    static func sessionFolders(defaults: UserDefaults = .standard) -> [URL] {
        let classes = base(forClass: true, defaults: defaults), calls = base(forClass: false, defaults: defaults)
        return classes.standardizedFileURL == calls.standardizedFileURL ? [classes] : [classes, calls]
    }

    /// Where a session goes: classes in the "Save to" folder, calls in the calls folder when one is set.
    static func base(forClass isClass: Bool, defaults: UserDefaults = .standard) -> URL {
        let classes = defaults.string(forKey: folder) ?? defaultFolder
        guard !isClass, let calls = defaults.string(forKey: callsFolder), !calls.isEmpty else { return URL(filePath: classes) }
        return URL(filePath: calls)
    }
}

/// When the words are written: once the call is over (only the sound is saved meanwhile, no model runs),
/// or live, as they are said.
enum TranscriptionMode: String, CaseIterable {
    case afterCall = "after"
    case live

    static var current: TranscriptionMode { TranscriptionMode(rawValue: UserDefaults.standard.string(forKey: Pref.mode) ?? "") ?? .afterCall }
}

/// One recording: capture, live transcription or saved sound, speaker names, auto-stop and saving.
@Observable @MainActor
final class Recorder {
    enum State { case idle, recording, finishing }

    /// 16 kHz mono AAC: what every session keeps as Audio.m4a.
    nonisolated(unsafe) static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
    ]

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
    /// Why the last session could not be transcribed.
    var failure: String? { state == .idle ? record?.failure : nil }
    /// How the current (or last) session is transcribed.
    var mode = TranscriptionMode.afterCall
    var onFinished: (SessionRecord) -> Void = { _ in }
    /// Work for after the call: the transcript itself, or telling the voices apart.
    var onQueued: (URL, TranscriptionQueue.Kind, String) -> Void = { _, _, _ in }
    /// Live subtitles, shown in their own window while `subtitlesOn`.
    let subtitles = SubtitleFeed()
    var subtitlesOn = false

    private var tap: AudioTap?
    /// The live transcribers, swapped in and out when the mode changes during a call.
    private let appSlot = TranscriberSlot()
    private let micSlot = TranscriberSlot()
    private var captions: TeamsCaptions?
    private var microphone: Microphone?
    private var mixer: MicMix?
    /// Part of this session was recorded "After the call": its whole transcript is written from the audio at the end.
    private var deferred = false
    private var timeline = SpeakerTimeline()
    private var audioTrack: RawTrack?
    private var appTrack: RawTrack?
    private var micTrack: RawTrack?
    private var watchdog: Timer?
    private var lastSound = Date()
    /// Recording a class from the calendar: breaks can be long and silent, so only the end of the class stops it.
    private var isClass = false
    /// The input the microphone was opened on.
    private var micUID: String?
    private var record: SessionRecord?
    private let subtitleSink = SubtitleSink()
    private var subtitleKind: SubtitleEngineKind?
    private var subtitleGeneration = 0

    init() {
        subtitles.speaker = { [weak self] in self?.timeline.latest }
        // The switch and the engine live in Settings (and the window's close button): follow them during a session.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSubtitles(); self?.refreshMicrophone() }
        }
    }

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
        let event = await CalendarLookup.currentEvent(for: app)
        let isClass = event?.isClass ?? false
        let group = event.map { isClass ? CalendarLookup.courseName($0.title) : $0.title } ?? app.name
        let folder = SessionStore.newFolder(base: Pref.base(forClass: isClass, defaults: defaults), group: group)

        let mode = TranscriptionMode.current
        self.mode = mode
        self.app = app
        title = event?.title ?? String(localized: "\(app.name) call")
        eventEnd = event?.end
        self.isClass = isClass
        startedAt = Date()
        segments = []
        preview = ""
        timeline = SpeakerTimeline()
        lastSound = Date()
        self.folder = folder
        record = SessionRecord(title: title, appName: app.name, bundleID: app.bundleID, startedAt: startedAt, duration: 0, segments: [])

        // After the call: no model while recording, only the sound is saved (and a level for the meter).
        deferred = mode == .afterCall
        let meter = LevelFeed { [weak self] rms in Task { @MainActor in self?.level = rms } }

        var mix: MicMix?
        if defaults.bool(forKey: Pref.includeMic) {
            if await Microphone.requestAccess() { mix = MicMix() } else { error = Microphone.Failure.denied.localizedDescription }
        }
        mixer = mix
        if mode == .live { startLive(model: model.url, at: 0) }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            audioTrack = try RawTrack(folder.appending(path: SessionStore.rawAudioName))
            if mix != nil {
                appTrack = try RawTrack(folder.appending(path: SessionStore.appTrackName))
                micTrack = try RawTrack(folder.appending(path: SessionStore.micTrackName))
            }
            let audio = audioTrack, appOnly = appTrack, micOnly = micTrack, sink = subtitleSink, live = appSlot, liveMic = micSlot, mixer = mix
            tap = try AudioTap(processes: app.processes) { samples in
                live.append(samples)
                meter.append(samples)
                sink.append(samples)
                appOnly?.append(samples)
                if let mixer {
                    let (mixed, mic, cleaned) = mixer.split(samples)
                    audio?.append(mixed)
                    micOnly?.append(mic)
                    liveMic.append(cleaned)
                } else {
                    audio?.append(samples)
                }
            }
            if mixer != nil { try openMicrophone() }
        } catch {
            self.error = error.localizedDescription
            cleanUp()
            return
        }

        if TeamsCaptions.handles(app.bundleID) { startCaptions(pid: app.pid) }
        state = .recording
        refreshSubtitles()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
        save()
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        tap?.stop()
        tap = nil
        refreshSubtitles()
        microphone?.stop()
        microphone = nil
        watchdog?.invalidate()
        // After the call there is nothing to flush: the sound is all saved.
        flushLive { [weak self] in Task { @MainActor in self?.finish() } }
    }

    /// Switches between live and after the call without starting a new session. Going live, the text starts
    /// from now on (the part before is written at the end, from the audio); going back, the live text so far stays
    /// until the whole session is transcribed from the audio at the end.
    func switchMode(to new: TranscriptionMode) {
        guard state == .recording, new != mode else { return }
        if new == .live {
            guard let model = WhisperModel.preferred(UserDefaults.standard.string(forKey: Pref.model) ?? "") else {
                error = String(localized: "No Whisper model found. Put a ggml model in ~/Library/Application Support/Earshot/Models.")
                return
            }
            startLive(model: model.url, at: elapsed)
        } else {
            deferred = true
            flushLive {}
            preview = ""
        }
        mode = new
    }

    /// Live transcribers for the app (and the microphone), their times counted from `offset` in the session.
    private func startLive(model: URL, at offset: TimeInterval) {
        let language = UserDefaults.standard.string(forKey: Pref.language) ?? "auto"
        let live = StreamingTranscriber(model: model, language: language)
        live.onCommit = { [weak self] segs in Task { @MainActor in self?.commit(segs.map { s in var s = s; s.start += offset; s.end += offset; return s }) } }
        live.onPreview = { [weak self] text in Task { @MainActor in
            guard let self, self.mode == .live else { return }
            self.preview = text
            self.previewSpeaker = self.timeline.latest
        } }
        live.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        appSlot.transcriber = live
        guard mixer != nil else { return }
        let mic = StreamingTranscriber(model: model, language: language)
        mic.onCommit = { [weak self] segs in
            Task { @MainActor in self?.commit(segs.map { s in var s = s; s.start += offset; s.end += offset; s.speaker = Microphone.speakerName; s.mic = true; return s }) }
        }
        micSlot.transcriber = mic
    }

    /// Takes the live transcribers off the audio and lets them write what they still hold, then calls `done`.
    private func flushLive(_ done: @escaping () -> Void) {
        let app = appSlot.take(), mic = micSlot.take()
        let finishMic: (@escaping () -> Void) -> Void = { next in if let mic { mic.finish(next) } else { next() } }
        if let app { app.finish { finishMic(done) } } else { finishMic(done) }
    }

    private func finish() {
        captions?.stop()
        attributeSpeakers(since: 0)
        // Live, a line of echo can slip through before the canceller has learned the room.
        segments = EchoLines.dropping(segments)
        for track in [audioTrack, appTrack, micTrack] { track?.close() }
        audioTrack = nil
        appTrack = nil
        micTrack = nil
        if deferred { record?.status = .pending }
        save()
        guard let folder else { cleanUp(); return }
        // Encoding an hour of sound takes a few seconds: off the main thread, the window stays responsive.
        Task.detached {
            try? SessionStore.finalizeAudio(in: folder)
            await MainActor.run { self.queueAfterRecording() }
        }
    }

    private func queueAfterRecording() {
        if let record, let folder {
            let voices = UserDefaults.standard.object(forKey: Pref.separateVoices) as? Bool ?? true
            if deferred {
                onQueued(folder, .transcribe, record.title)
            } else if voices, segments.contains(where: { $0.mic != true }) {
                onQueued(folder, .voices, record.title)
            } else if UserDefaults.standard.object(forKey: Pref.summarize) as? Bool ?? true, !segments.isEmpty {
                onQueued(folder, .summary, record.title)
            }
            onFinished(record)
        }
        cleanUp()
    }

    /// Shows a session again once its transcript or its voices are done (the transcript window keeps the last one).
    func refresh(_ updated: SessionRecord) {
        guard state == .idle, let folder, TranscriptionQueue.same(folder, updated.folder ?? folder) else { return }
        record = updated
        segments = updated.segments
    }

    /// Renames a speaker in the last session, once it is over.
    func rename(_ old: String?, to new: String) {
        guard state == .idle, var record, let folder else { return }
        record.segments = segments
        record.rename(old, to: new)
        segments = record.segments
        self.record = record
        SessionStore.write(record, to: folder)
        DocIndexer.shared.schedule()
    }


    func retryAccessibility() {
        TeamsCaptions.requestTrust()
        if let app, TeamsCaptions.isTrusted { startCaptions(pid: app.pid) }
    }

    /// Starts, switches or stops the subtitle engine to match the settings and the recording state.
    /// Opens the input chosen in Settings (again, when it changes during a recording: no new session needed).
    private func openMicrophone() throws {
        guard let mixer else { return }
        let uid = UserDefaults.standard.string(forKey: Pref.micDevice) ?? ""
        microphone?.stop()
        microphone = nil
        microphone = try Microphone(deviceUID: uid) { samples in mixer.addMic(samples) }
        micUID = uid
    }

    private func refreshMicrophone() {
        guard state == .recording, mixer != nil, (UserDefaults.standard.string(forKey: Pref.micDevice) ?? "") != micUID else { return }
        do { try openMicrophone() } catch { self.error = error.localizedDescription }
    }

    func refreshSubtitles() {
        let defaults = UserDefaults.standard
        let kind = SubtitleEngineKind(rawValue: defaults.string(forKey: Pref.subtitleEngine) ?? "") ?? .apple
        let wanted = state == .recording && defaults.bool(forKey: Pref.subtitles)
        if wanted && subtitlesOn && kind == subtitleKind { return }
        subtitleSink.swap(nil)?.stop()
        subtitleGeneration += 1
        subtitlesOn = wanted
        subtitleKind = wanted ? kind : nil
        guard wanted else { return }
        subtitles.clear()
        let generation = subtitleGeneration, feed = subtitles
        let language = defaults.string(forKey: Pref.language) ?? "auto"
        Task {
            do {
                let engine: SubtitleEngine = kind == .kyutai ? try KyutaiSubtitles(feed: feed) : try await AppleSubtitles(language: language, feed: feed)
                // Settings may have changed while the engine was starting.
                if generation == subtitleGeneration { subtitleSink.swap(engine) } else { engine.stop() }
            } catch {
                if generation == subtitleGeneration { feed.error = error.localizedDescription }
            }
        }
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

    /// Stops when the app quits, or when it has been silent for a while: for a class, once its calendar event
    /// is over (Teams keeps its audio running for the whole call, so a break does not count as silence);
    /// for a call, as soon as the app goes quiet, which is when the other side hangs up.
    private func check() {
        guard state == .recording, let app else { return }
        guard let fresh = app.refreshed() else { stop(); return }
        if fresh.processes != self.app?.processes { tap?.update(processes: fresh.processes); self.app = fresh }
        if fresh.isPlaying { lastSound = Date() }
        let quiet = Date().timeIntervalSince(lastSound)
        if isClass, let end = eventEnd { if Date() > end && quiet > 120 { stop() } } else if quiet > 120 { stop() }
        if captions == nil, needsAccessibility, TeamsCaptions.isTrusted { startCaptions(pid: app.pid) }
        // No new lines come in after the call: keep the duration and the names on disk anyway.
        if state == .recording, mode == .afterCall { save() }
    }

    /// Written after every new line, so a crash loses at most a few seconds of text.
    private func save() {
        guard var record, let folder else { return }
        record.segments = segments
        record.duration = elapsed
        if !timeline.marks.isEmpty { record.names = timeline.marks }
        self.record = record
        SessionStore.write(record, to: folder)
    }

    private func cleanUp() {
        tap?.stop(); tap = nil
        microphone?.stop(); microphone = nil
        captions?.stop(); captions = nil
        _ = appSlot.take()
        _ = micSlot.take()
        mixer = nil
        for track in [audioTrack, appTrack, micTrack] { track?.close() }
        audioTrack = nil
        appTrack = nil
        micTrack = nil
        watchdog?.invalidate(); watchdog = nil
        state = .idle
        preview = ""
        level = 0
    }
}

// MARK: - Calendar

/// The calendar event a recording belongs to.
struct CalendarEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    /// Location, link and notes: where a meeting link or the name of the call app usually is.
    var details: String = ""
    var isClass: Bool { CalendarLookup.isClass(title) }
}

enum CalendarLookup {
    private static let store = EKEventStore()

    /// The event being recorded (happening now, or starting within 30 min). For a class, `end` is the end of
    /// its last slot today, so a class split around a lunch break still counts as one session.
    static func currentEvent(for app: AudioApp? = nil) async -> CalendarEvent? {
        if CommandLine.arguments.contains("--no-calendar") { return nil }
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let all = store.events(matching: store.predicateForEvents(withStart: dayStart, end: dayStart.addingTimeInterval(86_400), calendars: nil))
            .filter { !$0.isAllDay }
            .map { e in
                CalendarEvent(title: e.title ?? "", start: e.startDate, end: e.endDate,
                              details: [e.location, e.url?.absoluteString, e.notes].compactMap { $0 }.joined(separator: "\n"))
            }
        guard var event = pick(all, app: app.map { "\($0.bundleID) \($0.name)" }, now: now) else { return nil }
        if event.isClass { event.end = all.filter { $0.title == event.title }.map(\.end).max() ?? event.end }
        return event
    }

    /// Call apps, by what names them in an event (its text) and in the app being recorded (its bundle id or name).
    private static let callApps: [(app: String, words: [String])] = [
        ("teams", ["teams", "teams.microsoft.com", "teams.live.com"]),
        ("whatsapp", ["whatsapp"]),
        ("zoom", ["zoom", "zoom.us"]),
        ("facetime", ["facetime"]),
        ("discord", ["discord"]),
        ("slack", ["slack"]),
        ("webex", ["webex"]),
        ("meet", ["meet.google.com", "google meet"]),
    ]

    /// Which call app a text names (or an app is): the first match, or nil.
    static func callApp(in text: String) -> String? {
        let t = text.lowercased()
        return callApps.first { entry in entry.words.contains { t.contains($0) } }?.app
    }

    /// The event that best fits a recording of `app` (bundle id and name), among today's events.
    /// A single event at that time is taken as it is. Only when several overlap does the app decide: an event
    /// that names another call app (a WhatsApp call while Teams records) gives way, one that names this app
    /// wins, then a class (a to-do set during a class is not what is being recorded), and otherwise the
    /// latest to start: the event that is just ending gives way to the one that is starting.
    /// Ticked-off to-dos are not meetings.
    static func pick(_ events: [CalendarEvent], app: String?, now: Date = Date()) -> CalendarEvent? {
        let recording = app.flatMap { name in callApps.first { $0.app != "meet" && name.lowercased().contains($0.app) }?.app }
        let current = events.filter { e in
            e.start <= now.addingTimeInterval(1800) && e.end >= now && !["✅", "☑", "✔"].contains(where: { e.title.hasPrefix($0) })
        }
        guard current.count > 1 else { return current.first }
        let fitting = current.filter { e in
            guard let recording, let named = callApp(in: e.title + "\n" + e.details) else { return true }
            return named == recording
        }
        let candidates = fitting.isEmpty ? current : fitting
        func score(_ e: CalendarEvent) -> Int {
            guard let recording else { return 0 }
            return callApp(in: e.title + "\n" + e.details) == recording ? 1 : 0
        }
        return candidates.max { a, b in (score(a), a.isClass ? 1 : 0, a.start) < (score(b), b.isClass ? 1 : 0, b.start) }
    }

    /// Classes are filed by school: "GEM : Course - Session 3". A call ("Nordine (Datadog) : call") is not.
    static func isClass(_ title: String) -> Bool {
        title.firstMatch(of: #/^[A-Z][A-Z0-9]{1,9} : /#) != nil
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
    static let audioName = "Audio.m4a"
    /// The sound while recording, raw so that nothing is lost if Earshot stops abruptly (see `RawTrack`).
    static let rawAudioName = ".audio.pcm"
    /// With the microphone included, the app and the microphone are also saved apart until the
    /// transcript is done, so the user's voice is never taken for someone else in the call.
    static let appTrackName = ".app.pcm"
    static let micTrackName = ".mic.pcm"

    /// Turns the raw sound of a finished (or interrupted) recording into Audio.m4a.
    nonisolated static func finalizeAudio(in folder: URL) throws {
        let raw = folder.appending(path: rawAudioName)
        guard FileManager.default.fileExists(atPath: raw.path) else { return }
        let samples = try RawTrack.read(raw)
        let audio = folder.appending(path: audioName)
        try? FileManager.default.removeItem(at: audio)
        try AudioFile.write(samples, to: audio)
        try FileManager.default.removeItem(at: raw)
    }

    static func load(_ folder: URL) -> SessionRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appending(path: recordName)), var r = try? decoder.decode(SessionRecord.self, from: data) else { return nil }
        r.folder = folder
        return r
    }

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
        // One text file per session, so a folder indexer finds each class once; Markdown and subtitles are exports.
        try? text(r).write(to: folder.appending(path: "Transcript.txt"), atomically: true, encoding: .utf8)
    }

    /// Sessions of several folders, each once even when one folder holds another.
    static func loadAll(bases: [URL]) -> [SessionRecord] {
        var seen = Set<String>()
        return bases.flatMap { loadAll(base: $0) }
            .filter { seen.insert($0.folder?.standardizedFileURL.path ?? $0.id.uuidString).inserted }
            .sorted { $0.startedAt > $1.startedAt }
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
