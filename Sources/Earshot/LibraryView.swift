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
        .onAppear { state.reloadLibrary() }
        .onChange(of: group) { selection = sessions.first?.id }
        .frame(minWidth: 820, minHeight: 480)
    }
}

private struct SessionRow: View {
    let record: SessionRecord
    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: record.bundleID).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(record.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) · \(record.duration.spoken)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SessionDetail: View {
    let record: SessionRecord
    let query: String

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
            TranscriptList(segments: record.segments, startedAt: record.startedAt, query: query)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Text (.txt)") { export("txt", .plainText, text: SessionStore.text(record)) }
                    Button("Markdown (.md)") { export("md", UTType(filenameExtension: "md") ?? .plainText, text: SessionStore.markdown(record)) }
                    Button("Subtitles (.srt)") { export("srt", UTType(filenameExtension: "srt") ?? .plainText, text: SessionStore.srt(record)) }
                    Divider()
                    Button("Audio (.m4a)") { export("m4a", .mpeg4Audio) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Button { if let f = record.folder { NSWorkspace.shared.open(f) } } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
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
