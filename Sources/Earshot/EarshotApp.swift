import SwiftUI

@main
struct EarshotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ViewState private var state = AppState()

    init() { SelfTest.runIfAsked() }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(state)
        } label: {
            MenuBarLabel().environment(state).onAppear { delegate.state = state }
        }
        .menuBarExtraStyle(.window)

        Window("Transcript", id: "transcript") {
            TranscriptWindow().environment(state)
        }
        .defaultSize(width: 440, height: 600)
        .defaultPosition(.topTrailing)
        .windowToolbarStyle(.unifiedCompact)

        Window("Live subtitles", id: "subtitles") {
            SubtitlesView().environment(state)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.bottom)

        Window("Library", id: "library") {
            LibraryView().environment(state)
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView()
        }
    }
}

/// ⌘Q, a logout or a restart while recording: the recording is stopped and its audio closed first,
/// otherwise Audio.m4a is left without its index and cannot be played or transcribed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = state?.recorder, recorder.isActive else { return .terminateNow }
        recorder.stop()
        Task { @MainActor in
            let deadline = Date.now.addingTimeInterval(15)
            while recorder.isActive && Date.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: state.recorder.isActive ? "ear.badge.waveform" : "ear")
            .onChange(of: state.recorder.subtitlesOn) { _, on in
                if on { openWindow(id: "subtitles") } else { dismissWindow(id: "subtitles") }
            }
            .onAppear {
                if state.demo { for id in state.demoWindows { if id == "settings" { openSettings() } else { openWindow(id: id) } } }
                // `--record <bundle ID prefix>`: start right away (testing without clicking).
                if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count,
                   let app = AudioApp.all().first(where: { $0.bundleID.hasPrefix(CommandLine.arguments[i + 1]) }) {
                    Task { await state.recorder.start(app); openWindow(id: "transcript") }
                }
            }
    }
}

@Observable @MainActor
final class AppState {
    let recorder = Recorder()
    let queue = TranscriptionQueue()
    var apps: [AudioApp] = []
    var event: (title: String, end: Date)?
    var library: [SessionRecord] = []
    /// `--demo`: fictional data, used for screenshots.
    let demo = CommandLine.arguments.contains("--demo")
    var demoWindows: [String] { CommandLine.arguments.drop { $0 != "--open" }.dropFirst().map { $0 } }

    private var base: URL { URL(filePath: UserDefaults.standard.string(forKey: Pref.folder) ?? Pref.defaultFolder) }

    init() {
        recorder.onFinished = { [weak self] _ in self?.reloadLibrary(); DocIndexer.shared.schedule() }
        recorder.onQueued = { [weak self] folder, kind, title in self?.queue.add(folder, kind: kind, title: title) }
        queue.hold = { [weak self] in self?.recorder.isActive ?? false }
        // Indexing waits for the call and for the transcripts: only one thing works at a time.
        DocIndexer.shared.hold = { [weak self] in guard let self else { return false }; return recorder.isActive || queue.current != nil }
        queue.onFinished = { [weak self] folder in
            guard let self else { return }
            reloadLibrary()
            DocIndexer.shared.schedule()
            if let record = SessionStore.load(folder) { recorder.refresh(record) }
        }
        if demo { Demo.fill(self) } else {
            reloadLibrary()
            // Sessions left waiting when Earshot quit pick up where they were. A recording cut short (forced quit,
            // crash) still has its raw sound: it is saved as Audio.m4a, then transcribed if it had no text yet.
            for r in library.reversed() {
                guard let f = r.folder else { continue }
                let cut = FileManager.default.fileExists(atPath: f.appending(path: SessionStore.rawAudioName).path)
                if r.status == .pending || (cut && r.segments.isEmpty) {
                    queue.add(f, kind: .transcribe, title: r.title)
                } else if cut {
                    queue.add(f, kind: .voices, title: r.title)
                }
            }
        }
    }

    func reloadLibrary() {
        guard !demo else { return }
        library = SessionStore.loadAll(bases: Pref.sessionFolders())
    }

    /// Imported audio or video files: each gets a session in "Imported files", transcribed like a recording.
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let folder = SessionStore.newFolder(base: base, group: String(localized: "Imported files"))
            let record = SessionRecord(title: url.deletingPathExtension().lastPathComponent, appName: String(localized: "File"), bundleID: "",
                                       startedAt: created, duration: 0, segments: [], status: .pending, source: url.path)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                continue
            }
            SessionStore.write(record, to: folder)
            queue.add(folder, kind: .transcribe, title: record.title)
        }
        reloadLibrary()
    }

    /// Transcribes a saved session again from its audio: voices and the language of each sentence included.
    func retranscribe(_ record: SessionRecord) {
        guard let folder = record.folder else { return }
        queue.add(folder, kind: .transcribe, title: record.title)
    }

    /// Renames a speaker in a saved session, and in the transcript window if it shows that session.
    func rename(_ old: String?, to new: String, in record: SessionRecord) {
        guard let folder = record.folder, var saved = SessionStore.load(folder) else { return }
        saved.rename(old, to: new)
        SessionStore.write(saved, to: folder)
        DocIndexer.shared.schedule()
        recorder.refresh(saved)
        reloadLibrary()
    }

    /// Asks for a speaker's new name. Nil when cancelled or left empty.
    static func askName(for speaker: String?) -> String? {
        let old = speaker ?? String(localized: "Speaker")
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename \(old)")
        alert.informativeText = String(localized: "Every line from this speaker in this session takes the new name.")
        let field = NSTextField(string: speaker ?? "")
        field.placeholderString = String(localized: "Name")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == speaker ? nil : name
    }
}
