import SwiftUI

@main
struct EarshotApp: App {
    @ViewState private var state = AppState()

    init() { SelfTest.runIfAsked() }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(state)
        } label: {
            MenuBarLabel().environment(state)
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

private struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Image(systemName: state.recorder.isActive ? "ear.badge.waveform" : "ear")
            .onChange(of: state.recorder.subtitlesOn) { _, on in
                if on { openWindow(id: "subtitles") } else { dismissWindow(id: "subtitles") }
            }
            .onAppear {
                if state.demo { for id in state.demoWindows { openWindow(id: id) } }
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
    var apps: [AudioApp] = []
    var event: (title: String, end: Date)?
    var library: [SessionRecord] = []
    /// `--demo`: fictional data, used for screenshots.
    let demo = CommandLine.arguments.contains("--demo")
    var demoWindows: [String] { CommandLine.arguments.drop { $0 != "--open" }.dropFirst().map { $0 } }

    init() {
        recorder.onFinished = { [weak self] _ in self?.reloadLibrary() }
        if demo { Demo.fill(self) } else { reloadLibrary() }
    }

    func reloadLibrary() {
        guard !demo else { return }
        let base = URL(filePath: UserDefaults.standard.string(forKey: Pref.folder) ?? Pref.defaultFolder)
        library = SessionStore.loadAll(base: base)
    }
}
