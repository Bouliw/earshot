import SwiftUI

/// Floating window with the live transcript of the current (or last) session.
struct TranscriptWindow: View {
    @Environment(AppState.self) private var state
    @ViewState private var query = ""
    @ViewState private var copied = false

    var body: some View {
        let rec = state.recorder
        VStack(spacing: 0) {
            if rec.needsAccessibility {
                Banner(icon: "person.wave.2", text: Text("Allow Earshot in \(TeamsCaptions.settingName) to see who is speaking."), action: "Allow…") { rec.retryAccessibility() }
            }
            if let error = rec.error { Banner(icon: "exclamationmark.triangle.fill", text: Text(error)) }
            if rec.segments.isEmpty && rec.preview.isEmpty {
                ContentUnavailableView {
                    Label(rec.isActive ? "Listening…" : "Nothing recorded yet", systemImage: rec.isActive ? "waveform" : "ear")
                } description: {
                    Text(rec.isActive ? "Text appears here as soon as someone speaks." : "Pick an app from the menu bar to start.")
                }
            } else {
                TranscriptList(segments: rec.segments, startedAt: rec.startedAt, query: query,
                               live: rec.state == .recording ? (rec.previewSpeaker, rec.preview) : nil)
            }
        }
        .frame(minWidth: 360, minHeight: 280)
        .navigationTitle(rec.title.isEmpty ? String(localized: "Transcript") : rec.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .navigation) { StatusPill() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    copyAll()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                }
                .help("Copy the whole transcript")
                if rec.state == .recording {
                    Button { rec.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                        .help("Stop and save")
                } else if let folder = rec.folder, rec.state == .idle {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "Transcript.txt")]) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
            }
        }
        .containerBackground(.thickMaterial, for: .window)
    }

    private var subtitle: String {
        let rec = state.recorder
        var parts = [rec.app?.name ?? ""]
        if rec.state == .idle, !rec.segments.isEmpty { parts.append(String(localized: "Saved")) }
        if let end = rec.eventEnd, rec.isActive { parts.append(String(localized: "until \(end.formatted(date: .omitted, time: .shortened))")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func copyAll() {
        let rec = state.recorder
        let record = SessionRecord(title: rec.title, appName: rec.app?.name ?? "", bundleID: "", startedAt: rec.startedAt, duration: rec.elapsed, segments: rec.segments)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SessionStore.text(record), forType: .string)
        withAnimation { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
    }
}

/// Red dot + elapsed time while recording.
private struct StatusPill: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let rec = state.recorder
        if rec.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    if rec.state == .finishing { ProgressView().controlSize(.mini) } else { PulsingDot() }
                    (rec.state == .finishing ? Text("Saving") : Text(rec.elapsed.clock)).monospacedDigit()
                    LevelMeter(level: rec.level)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 8)
            }
        }
    }
}

/// The transcript, followed live until the user scrolls up, then with a way back. The text is a single
/// AppKit text view (TranscriptText.swift), so a selection, ⌘A and ⌘C cover every turn at once.
struct TranscriptList: View {
    let segments: [Segment]
    let startedAt: Date
    var query = ""
    /// (speaker, text) of the line being spoken, nil when not live.
    var live: (String?, String)? = nil

    @ViewState private var following = true
    /// Bumped by "Back to live" to scroll down with an animation.
    @ViewState private var jump = 0

    private var turns: [Turn] {
        let all = Turn.group(segments)
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.speaker ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let turns = self.turns
        VStack(alignment: .leading, spacing: 0) {
            if !query.isEmpty {
                (turns.isEmpty ? Text("No match") : Text("Matches: \(turns.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            TranscriptText(turns: turns, startedAt: startedAt, query: query, live: query.isEmpty ? live : nil,
                           following: $following, jump: jump)
        }
        .overlay(alignment: .bottom) {
            if !following && live != nil && query.isEmpty {
                Button {
                    following = true
                    jump += 1
                } label: {
                    Label("Back to live", systemImage: "arrow.down")
                }
                .buttonStyle(.glassProminent)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: following)
    }
}

private struct Banner: View {
    let icon: String
    let text: Text
    var action: LocalizedStringKey? = nil
    var perform: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange)
            text.font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action, action: perform).buttonStyle(.glass) }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .padding([.horizontal, .top], 12)
    }
}
