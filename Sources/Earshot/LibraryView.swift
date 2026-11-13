import SwiftUI
import UniformTypeIdentifiers

/// All saved sessions, grouped by calendar event.
struct LibraryView: View {
    @Environment(AppState.self) private var state
    @ViewState private var group: String? = nil
    @ViewState private var selection: SessionRecord.ID?
    @ViewState private var query = ""

    private var groups: [(name: String, count: Int)] {
        Dictionary(grouping: state.library, by: \.group).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    private var sessions: [SessionRecord] {
        state.library.filter { group == nil || $0.group == group }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $group) {
                Label("All Sessions", systemImage: "tray.full").badge(state.library.count).tag(nil as String?)
                Section("Folders") {
                    ForEach(groups, id: \.name) { g in
                        Label(g.name, systemImage: "folder").badge(g.count).tag(g.name as String?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            List(sessions, selection: $selection) { r in SessionRow(record: r) }
                .overlay { if sessions.isEmpty { ContentUnavailableView("No sessions", systemImage: "waveform", description: Text("Recordings show up here once saved.")) } }
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let r = state.library.first(where: { $0.id == selection }) {
                SessionDetail(record: r, query: query)
            } else {
                ContentUnavailableView("Select a session", systemImage: "text.bubble")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcript")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { pickFiles() } label: { Label("Transcribe a file…", systemImage: "doc.badge.plus") }
                    .help("Transcribe audio or video files, with each voice")
            }
        }
        // Audio or video dropped on the window is transcribed like a recording.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .audio) || type.conforms(to: .movie)
            }
            guard !files.isEmpty else { return false }
            state.importFiles(files)
            group = nil
            return true
        }
        .onAppear { state.reloadLibrary() }
        .onChange(of: group) { selection = sessions.first?.id }
        .frame(minWidth: 820, minHeight: 480)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = String(localized: "Choose audio or video files to transcribe.")
        panel.prompt = String(localized: "Transcribe")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        state.importFiles(panel.urls)
        group = nil
    }
}

private struct SessionRow: View {
    @Environment(AppState.self) private var state
    let record: SessionRecord
    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: record.bundleID).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.body.weight(.medium)).lineLimit(1)
                Group {
                    if let work = state.queue.status(of: record.folder) {
                        if work.waiting { Text("Waiting to be transcribed") }
                        else {
                            let percent = work.progress.formatted(.percent.precision(.fractionLength(0)))
                            switch work.kind {
                            case .voices: Text("Telling voices apart · \(percent)")
                            case .summary: Text("Summarizing · \(percent)")
                            case .transcribe: Text("Transcribing · \(percent)")
                            }
                        }
                    } else if record.status == .failed {
                        Text("Could not be transcribed").foregroundStyle(.orange)
                    } else {
                        Text("\(record.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) · \(record.duration.spoken)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SessionDetail: View {
    @Environment(AppState.self) private var state
    let record: SessionRecord
    let query: String

    private var hasAudio: Bool { record.folder.map { FileManager.default.fileExists(atPath: $0.appending(path: SessionStore.audioName).path) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AppIcon(bundleID: record.bundleID).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.title2.weight(.semibold))
                    Text("\(record.startedAt.formatted(date: .complete, time: .shortened)) · \(record.duration.spoken) · \(speakers)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Divider()
            let work = state.queue.status(of: record.folder)
            if let work, work.kind == .summary, !work.waiting {
                Banner(icon: "sparkles", text: Text("Summarizing…")) {
                    ProgressView(value: work.progress).frame(width: 80)
                }
            } else if let work, work.kind == .voices || !record.segments.isEmpty {
                Banner(icon: "person.2.wave.2", text: Text(work.kind == .voices ? "Telling voices apart…" : (work.waiting ? "Waiting to be transcribed again" : "Transcribing again…"))) {
                    ProgressView(value: work.progress).frame(width: 80)
                }
            }
            if let work, record.segments.isEmpty {
                TranscribingView(waiting: work.waiting, progress: work.progress)
            } else if record.status == .failed && record.segments.isEmpty {
                ContentUnavailableView {
                    Label("Could not be transcribed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(record.failure ?? "")
                } actions: {
                    Button("Try again") { state.retranscribe(record) }.buttonStyle(.glassProminent)
                }
            } else if record.status == .pending && record.segments.isEmpty {
                TranscribingView(waiting: true, progress: 0)
            } else {
                SummaryCard(folder: record.folder)
                TranscriptList(segments: record.segments, startedAt: record.startedAt, query: query,
                               onRename: work == nil ? { old in if let new = AppState.askName(for: old) { state.rename(old, to: new, in: record) } } : nil)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !record.speakers.isEmpty || !record.segments.isEmpty {
                    Menu {
                        ForEach(speakerChoices, id: \.self) { name in
                            Button(name ?? String(localized: "Speaker")) {
                                if let new = AppState.askName(for: name) { state.rename(name, to: new, in: record) }
                            }
                        }
                    } label: {
                        Label("Rename a speaker", systemImage: "person.text.rectangle")
                    }
                    .help("Rename a speaker in this session")
                    .disabled(state.queue.status(of: record.folder) != nil)
                }
                if CallSummarizer.isAvailable {
                    Button { state.summarize(record) } label: {
                        Label(Summary.load(record.folder) == nil ? "Summarize" : "Summarize again", systemImage: "sparkles")
                    }
                    .help("Write the summary of this session again: key points, decisions and who does what")
                    .disabled(record.segments.isEmpty || state.queue.status(of: record.folder) != nil)
                }
                Button { state.retranscribe(record) } label: { Label("Transcribe again", systemImage: "arrow.clockwise") }
                    .help("Transcribe again from the audio: each voice told apart, each sentence in its own language")
                    .disabled(!hasAudio || state.queue.status(of: record.folder) != nil)
                Menu {
                    Button("Text (.txt)") { export("txt", .plainText, text: SessionStore.text(record)) }
                    Button("Markdown (.md)") { export("md", UTType(filenameExtension: "md") ?? .plainText, text: SessionStore.markdown(record)) }
                    Button("Subtitles (.srt)") { export("srt", UTType(filenameExtension: "srt") ?? .plainText, text: SessionStore.srt(record)) }
                    if let summary = Summary.load(record.folder) {
                        Button("Summary (.txt)") { export("txt", .plainText, text: summary) }
                    }
                    Divider()
                    Button("Audio (.m4a)") { export("m4a", .mpeg4Audio) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Button { if let f = record.folder { NSWorkspace.shared.open(f) } } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
    }

    /// Every speaker, in order of appearance (nil: lines without a name).
    private var speakerChoices: [String?] {
        var seen: [String?] = []
        for s in record.segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    private var speakers: String {
        let names = Set(record.segments.compactMap(\.speaker))
        if names.isEmpty { return record.appName }
        return names.count == 1 ? String(localized: "1 speaker") : String(localized: "\(names.count) speakers")
    }

    /// Saves `text`, or the session's audio when there is no text.
    private func export(_ ext: String, _ type: UTType, text: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(record.title) — \(record.startedAt.formatted(.iso8601.year().month().day())).\(ext)"
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        if let text {
            try? text.write(to: target, atomically: true, encoding: .utf8)
        } else if let audio = record.folder?.appending(path: "Audio.m4a") {
            try? FileManager.default.copyItem(at: audio, to: target)
        }
    }
}

struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            AppMark(size: 28)
        }
    }
}
