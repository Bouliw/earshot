import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.model) private var model = ""
    @AppStorage(Pref.folder) private var folder = Pref.defaultFolder
    @AppStorage(Pref.autoCaptions) private var autoCaptions = true
    private let models = WhisperModel.installed()

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $language) {
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
                LabeledContent("Save to") {
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: choose)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("Each session goes in a folder named after its calendar event, then the date.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Turn on Teams live captions automatically", isOn: $autoCaptions)
            } header: {
                Text("Speaker names")
            } footer: {
                Text("Teams captions tell Earshot who is speaking. Only you see them.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
