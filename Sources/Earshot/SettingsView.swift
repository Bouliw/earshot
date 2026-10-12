import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage(Pref.model) private var model = ""
    @AppStorage(Pref.folder) private var folder = Pref.defaultFolder
    @AppStorage(Pref.autoCaptions) private var autoCaptions = true
    @AppStorage(Pref.subtitles) private var subtitles = false
    @AppStorage(Pref.subtitleSize) private var subtitleSize = 24.0
    @ViewState private var trusted = TeamsCaptions.isTrusted
    private let models = WhisperModel.installed()

    var body: some View {
        Form {
            Section {
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
            Section("Transcription") {
                Picker("Spoken language", selection: $language) {
                    Text("Automatic").tag("auto")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                }
                Picker("Model", selection: Binding(get: { WhisperModel.preferred(model)?.id ?? "" }, set: { model = $0 })) {
                    ForEach(models) { m in Text(m.name).tag(m.id) }
                }
                .disabled(models.isEmpty)
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
            } header: {
                Text("Sessions")
            } footer: {
                Text("Each session goes in a folder named after its calendar event, then the date. The transcript is a plain text file, so a folder indexer such as doc-indexer can search it with your documents.").foregroundStyle(.secondary)
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
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
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
