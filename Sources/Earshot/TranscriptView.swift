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
            let work = rec.isActive ? nil : state.queue.status(of: rec.folder)
            if let work, work.kind == .summary, !work.waiting {
                Banner(icon: "sparkles", text: Text("Summarizing…")) {
                    ProgressView(value: work.progress).frame(width: 80)
                }
            } else if let work, work.kind == .voices || !rec.segments.isEmpty {
                Banner(icon: "person.2.wave.2", text: Text(work.kind == .voices ? "Telling voices apart…" : "Transcribing again…")) {
                    ProgressView(value: work.progress).frame(width: 80)
                }
            }
            if let failure = rec.failure, rec.segments.isEmpty {
                Banner(icon: "exclamationmark.triangle.fill", text: Text(failure))
            }
            if rec.segments.isEmpty && rec.preview.isEmpty {
                if let work {
                    TranscribingView(waiting: work.waiting, progress: work.progress)
                } else if rec.isActive && rec.mode == .afterCall {
                    ContentUnavailableView {
                        Label("Recording", systemImage: "record.circle")
                    } description: {
                        Text("The transcript is written when the call ends, with each voice. No model runs during the call.")
                    } actions: {
                        RecordingActions()
                    }
                    .padding(.bottom, 48)
                } else {
                    ContentUnavailableView {
                        Label(rec.isActive ? "Listening…" : "Nothing recorded yet", systemImage: rec.isActive ? "waveform" : "ear")
                    } description: {
                        Text(rec.isActive ? "Text appears here as soon as someone speaks." : "Pick an app from the menu bar to start.")
                    } actions: {
                        if rec.isActive { RecordingActions() }
                    }
                    .padding(.bottom, rec.isActive ? 48 : 0)
                }
            } else {
                if rec.state == .idle { SummaryCard(folder: rec.folder) }
                TranscriptList(segments: rec.segments, startedAt: rec.startedAt, query: query,
                               live: rec.state == .recording ? (rec.previewSpeaker, rec.preview) : nil,
                               onRename: rec.state == .idle && work == nil ? { old in if let new = AppState.askName(for: old) { rec.rename(old, to: new); state.reloadLibrary() } } : nil)
                // Once text fills the window, Stop moves from the middle to a bar that stays at the bottom.
                if rec.isActive { RecordingBar() }
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
                    // Labels, not bare images: a narrow window moves these into the » menu, which shows the titles.
                    Label("Copy the whole transcript", systemImage: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                }
                .help("Copy the whole transcript")
                // No Stop here: it is always in the window itself, in the middle or in the bottom bar.
                if let folder = rec.folder, rec.state == .idle {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "Transcript.txt")]) } label: { Label("Show in Finder", systemImage: "folder") }
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

/// The red Stop button, with its shortcut written on it (⌘↩), shared by the middle of the window and the bottom bar.
private struct StopButton: View {
    @Environment(AppState.self) private var state
    var large = false

    var body: some View {
        let rec = state.recorder
        Button { rec.stop() } label: {
            HStack(spacing: 8) {
                Label(rec.mode == .live ? "Stop and save" : "Stop and transcribe", systemImage: "stop.fill")
                Text("⌘↩").font(.caption.weight(.medium)).opacity(0.7)
            }
            .frame(minWidth: large ? 200 : nil)
        }
        .buttonStyle(.glassProminent).tint(.red).controlSize(large ? .large : .regular)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(rec.state != .recording)
    }
}

/// Switching mode mid-call is rare: a quiet link, so it is never clicked instead of Stop.
private struct ModeLink: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let rec = state.recorder
        let live = rec.mode == .live
        Button(live ? "Transcribe after the call instead" : "Transcribe live instead") { rec.switchMode(to: live ? .afterCall : .live) }
            .buttonStyle(.link).font(.callout)
            .disabled(rec.state != .recording)
            .help(live ? "Stop the model now; the rest is transcribed from the audio after the call" : "Words appear as they are said; the Mac works harder during the call")
    }
}

/// Under the "Recording" message while the window is still empty.
private struct RecordingActions: View {
    var body: some View {
        VStack(spacing: 12) {
            StopButton(large: true)
            SubtitlesToggle()
            ModeLink()
        }
        .padding(.top, 6)
    }
}

/// Pinned to the bottom while recording once text is shown, so Stop never scrolls away or hides in the toolbar.
private struct RecordingBar: View {
    var body: some View {
        // Side by side when the window is wide enough, stacked in a narrow one.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ModeLink(); Spacer(minLength: 12); SubtitlesToggle(); StopButton() }
            VStack(spacing: 8) { HStack(spacing: 8) { SubtitlesToggle(); StopButton() }; ModeLink() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
    /// Makes speaker names clickable, to rename them.
    var onRename: ((String?) -> Void)? = nil

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
                           following: $following, jump: jump, onRename: onRename)
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

/// A session waiting for its transcript, or being transcribed.
struct TranscribingView: View {
    @Environment(AppState.self) private var state
    let waiting: Bool
    let progress: Double
    private var paused: Bool { state.queue.paused }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.word.spacing").font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: !waiting)
            Text(waiting ? "Waiting to be transcribed" : "Transcribing…").font(.title3.weight(.semibold))
            if paused { Text("Waits for the recording to end, so nothing heavy runs meanwhile").font(.callout).foregroundStyle(.secondary) }
            if !waiting {
                ProgressView(value: progress).frame(width: 220).animation(.smooth, value: progress)
                Text(progress, format: .percent.precision(.fractionLength(0))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Each voice is told apart, and each sentence keeps its language. Everything runs on this Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct Banner<Trailing: View>: View {
    let icon: String
    let text: Text
    var action: LocalizedStringKey? = nil
    var perform: () -> Void = {}
    var trailing: Trailing

    init(icon: String, text: Text, action: LocalizedStringKey? = nil, perform: @escaping () -> Void = {}) where Trailing == EmptyView {
        self.init(icon: icon, text: text, action: action, perform: perform) { EmptyView() }
    }

    init(icon: String, text: Text, action: LocalizedStringKey? = nil, perform: @escaping () -> Void = {}, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.text = text
        self.action = action
        self.perform = perform
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange)
            text.font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing
            if let action { Button(action, action: perform).buttonStyle(.glass) }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .padding([.horizontal, .top], 12)
    }
}
