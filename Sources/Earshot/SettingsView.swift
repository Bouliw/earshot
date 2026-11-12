import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage(Pref.model) private var model = ""
    @AppStorage(Pref.folder) private var folder = Pref.defaultFolder
    @AppStorage(Pref.callsFolder) private var callsFolder = ""
    @AppStorage(Pref.autoCaptions) private var autoCaptions = true
    @AppStorage(Pref.subtitles) private var subtitles = false
    @AppStorage(Pref.subtitleSize) private var subtitleSize = 24.0
    @AppStorage(Pref.mode) private var mode = TranscriptionMode.afterCall.rawValue
    @AppStorage(Pref.separateVoices) private var separateVoices = true
    @AppStorage(Pref.indexTranscripts) private var indexTranscripts = false
    @AppStorage(Pref.indexer) private var indexer = ""
    @AppStorage(Pref.indexFolder) private var indexFolder = ""
    @ViewState private var trusted = TeamsCaptions.isTrusted
    @ViewState private var openAtLogin = SMAppService.mainApp.status == .enabled
    private let models = WhisperModel.installed()

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .id("top")
                    .toggleStyle(.checkbox)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("App language", selection: $interfaceLanguage) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Français").tag("fr")
                }
                .onChange(of: interfaceLanguage) { _, value in
                    if value == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([value], forKey: "AppleLanguages") }
                }
            } footer: {
                Text("Takes effect the next time Earshot opens.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Transcribe", selection: $mode) {
                    Text("After the call").tag(TranscriptionMode.afterCall.rawValue)
                    Text("Live").tag(TranscriptionMode.live.rawValue)
                }
                Toggle("Tell voices apart", isOn: $separateVoices)
                MicPicker()
                Picker("Spoken language", selection: $language) {
                    Text("Automatic").tag("auto")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                }
                Picker("Model", selection: Binding(get: { WhisperModel.preferred(model)?.id ?? "" }, set: { model = $0 })) {
                    ForEach(models) { m in Text(m.name).tag(m.id) }
                }
                .disabled(models.isEmpty)
            } header: {
                Text("Transcription")
            } footer: {
                Text("After the call, only the sound is saved while you talk: the Mac stays cool, and the transcript that follows gives each sentence its own language. Voices are told apart on this Mac once the call ends (about 40 MB downloaded the first time); Teams names are used when Earshot can see them, “Speaker 1”, “Speaker 2”… otherwise. Click a name in a transcript to rename it.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show live subtitles", isOn: $subtitles)
                EngineRow(kind: .apple, title: "Fast", detail: "Apple's on-device recognition. Responsive and light, nothing to download, one language at a time.")
                EngineRow(kind: .kyutai, title: "High", detail: "Kyutai STT 1B (MLX). Built for live speech, handles French and English mixed, about 0.5 s behind.")
                LabeledContent("Text size") {
                    Slider(value: $subtitleSize, in: 14...48, step: 2).frame(width: 180)
                }
            } header: {
                Text("Live subtitles")
            } footer: {
                Text("A small window shows the last two lines said in the app you transcribe. Everything runs on this Mac.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: choose)
                    }
                }
                LabeledContent("Calls") {
                    HStack {
                        Text(callsFolder.isEmpty ? String(localized: "Same folder") : (callsFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        if !callsFolder.isEmpty { Button("Reset") { callsFolder = "" } }
                        Button("Choose…", action: chooseCalls)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("Each session goes in a folder named after its calendar event, then the date, with its transcript as a plain text file. Classes (calendar events like \"SCHOOL : Course\") go in the first folder, calls in the second.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Index transcripts with doc-indexer", isOn: $indexTranscripts)
                    .onChange(of: indexTranscripts) { _, on in
                        guard on else { return }
                        if DocIndexer.script == nil { chooseIndexer() }
                        if DocIndexer.script == nil { indexTranscripts = false } else { DocIndexer.shared.indexNow() }
                    }
                if indexTranscripts {
                    LabeledContent("doc-indexer") {
                        HStack {
                            Text(DocIndexer.script.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath } ?? String(localized: "Not found"))
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                .id(indexer)  // read again once another one is chosen
                            Button("Choose…", action: chooseIndexer)
                        }
                    }
                    LabeledContent("Folder to index") {
                        HStack {
                            Text(((indexFolder.isEmpty ? folder : indexFolder) as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose…", action: chooseIndexFolder)
                        }
                    }
                    IndexStatusRow()
                }
            } header: {
                Text("Search with your documents")
            } footer: {
                Text("After each transcript, once no call is being recorded, Earshot runs doc-indexer on this folder at low priority, so the Mac stays cool. Your transcripts and documents can then be searched together in its hidden .doc-index folder. Nothing leaves this Mac.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(TeamsCaptions.settingName) {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { TeamsCaptions.requestTrust() }
                    }
                }
                Toggle("Turn on Teams live captions automatically", isOn: $autoCaptions)
            } header: {
                Text("Speaker names")
            } footer: {
                Text("Teams captions tell Earshot who is speaking. Only you see them.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // The grant happens in System Settings, so watch for it while this window is open.
            while !Task.isCancelled { trusted = TeamsCaptions.isTrusted; try? await Task.sleep(for: .seconds(1)) }
        }
        // Fixed height: the grouped form scrolls, so the window fits on a laptop screen.
        .frame(width: 480, height: 560)
        .defaultScrollAnchor(.top)
        // The window keeps its last scroll position and follows the focused control: always open at the top.
        .onAppear {
            proxy.scrollTo("top", anchor: .top)
            Task { try? await Task.sleep(for: .milliseconds(150)); proxy.scrollTo("top", anchor: .top) }
        }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func chooseCalls() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: callsFolder.isEmpty ? folder : callsFolder)
        if panel.runModal() == .OK, let url = panel.url { callsFolder = url.path }
    }

    /// doc-indexer's folder or its extract_texts.py.
    private func chooseIndexer() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose your doc-indexer-macos folder, or extract_texts.py in it.")
        panel.directoryURL = DocIndexer.script?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let script = DocIndexer.script(from: url) { indexer = script.path; DocIndexer.shared.indexNow() }
    }

    /// The sessions folder, or a folder that holds it (Documents…) to search sessions and documents together.
    private func chooseIndexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose the folder of your sessions, or a folder that holds it to search them with your documents.")
        panel.directoryURL = DocIndexer.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        indexFolder = url.path
        DocIndexer.shared.indexNow()
    }
}

/// How the last doc-indexer run went, and a button to run it now.
private struct IndexStatusRow: View {
    private var indexer: DocIndexer { .shared }

    var body: some View {
        HStack(spacing: 8) {
            switch indexer.state {
            case .idle:
                Text("Runs after the next transcript").foregroundStyle(.secondary)
            case .waiting:
                Label("Waits for the call or the transcript to end", systemImage: "clock").foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
                Text("Indexing…").foregroundStyle(.secondary)
            case let .done(date, files):
                Label(String(localized: "Indexed: \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)) · \(files) files"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Index now") { indexer.indexNow() }
                .disabled(indexer.state == .running)
        }
        .font(.callout)
    }
}

/// One subtitle engine: its level, what it is good at, and whether it is in use, ready or still to install.
private struct EngineRow: View {
    let kind: SubtitleEngineKind
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @AppStorage(Pref.subtitleEngine) private var engine = SubtitleEngineKind.apple.rawValue
    @ViewState private var confirm = false
    private var kyutai: Kyutai { .shared }
    private var needsInstall: Bool { kind == .kyutai && kyutai.state != .installed }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if needsInstall, case let .failed(message) = kyutai.state {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if needsInstall {
                if case let .installing(progress) = kyutai.state {
                    ProgressView(value: progress).frame(width: 70)
                    Button("Cancel") { kyutai.cancel() }
                } else {
                    Button("Install (\(Kyutai.size))") { confirm = true }
                }
            } else if engine == kind.rawValue {
                Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Use") { engine = kind.rawValue }
            }
        }
        .alert("Download High subtitles?", isPresented: $confirm) {
            Button("Download") { kyutai.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Kyutai.size) to download: the Kyutai model from Hugging Face and its Python packages, into ~/Library/Application Support/Earshot/Kyutai. Needs Python 3.10 to 3.12.")
        }
    }
}
