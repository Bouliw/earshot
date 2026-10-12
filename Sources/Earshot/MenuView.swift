import SwiftUI

/// The popover under the menu bar icon: apps playing sound, one click to start.
struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var showQuiet = false

    private var playing: [AudioApp] { state.apps.filter(\.isPlaying) }
    private var quiet: [AudioApp] { state.apps.filter { !$0.isPlaying } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if state.recorder.isActive {
                RecordingCard()
            } else {
                if let event = state.event { EventChip(title: event.title, end: event.end) }
                appList
            }
            if let error = state.recorder.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .task {
            // Refresh while the popover is open; `.task` stops when it closes.
            if !state.demo { state.event = await CalendarLookup.currentEvent() }
            while !Task.isCancelled {
                if !state.demo { state.apps = AudioApp.all() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Earshot").font(.headline)
                Text(state.recorder.isActive ? "Transcribing on this Mac" : "Pick an app to transcribe")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSApp.activate(); openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
    }

    @ViewBuilder private var appList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if playing.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.slash").font(.title2).foregroundStyle(.tertiary)
                    Text("No app is playing sound").font(.callout.weight(.medium))
                    Text("Join your call: it will show up here.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                SectionTitle("Playing now")
                ForEach(playing) { app in AppRow(app: app) { start(app) } }
            }
            if !quiet.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { showQuiet.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        SectionTitle("Other apps")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showQuiet ? 90 : 0))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 6)
                if showQuiet { ForEach(quiet) { app in AppRow(app: app) { start(app) }.opacity(0.8) } }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { show("library") } label: { Label("Library", systemImage: "books.vertical") }
            if state.recorder.isActive || !state.recorder.segments.isEmpty {
                Button { show("transcript") } label: { Label("Transcript", systemImage: "text.bubble") }
            }
            Spacer()
            Button("Quit") { state.recorder.stop(); NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
    }

    private func start(_ app: AudioApp) {
        Task {
            await state.recorder.start(app)
            if state.recorder.isActive { show("transcript") }
        }
    }

    private func show(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
    }
}

private struct AppRow: View {
    let app: AudioApp
    let action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(app.isPlaying ? "Playing sound" : "Quiet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hover {
                    Label("Transcribe", systemImage: "record.circle")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.red.gradient, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if app.isPlaying {
                    Equalizer().frame(width: 18, height: 14)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// Small animated bars for an app that is playing sound.
struct Equalizer: View {
    var color: Color = .green
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { i in
                    let phase = sin(t * (5.0 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule().fill(color.gradient).frame(width: 3).frame(height: 4 + 10 * (0.5 + 0.5 * phase))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Live level of the captured sound.
struct LevelMeter: View {
    let level: Float
    var body: some View {
        let db = 20 * log10(max(Double(level), 0.000_01))       // -100...0
        let fill = min(1, max(0, (db + 60) / 50))                // -60 dB -> empty, -10 dB -> full
        HStack(spacing: 2) {
            ForEach(0..<8) { i in
                Capsule().fill(Double(i) / 8 < fill ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 6 + CGFloat(i))
            }
        }
        .animation(.easeOut(duration: 0.12), value: fill)
    }
}

private struct RecordingCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rec = state.recorder
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = rec.app?.icon { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title).font(.headline).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 5) {
                            if rec.state == .finishing {
                                ProgressView().controlSize(.mini)
                                Text("Finishing…")
                            } else {
                                PulsingDot()
                                Text("Recording · \(rec.elapsed.clock)").monospacedDigit()
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                LevelMeter(level: rec.level)
            }
            if let last = rec.preview.isEmpty ? rec.segments.last?.text : rec.preview {
                Text(last).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
            HStack {
                Button { NSApp.activate(); openWindow(id: "transcript") } label: { Label("Show transcript", systemImage: "text.bubble") }
                    .buttonStyle(.glass)
                Spacer()
                Button { rec.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.glassProminent).tint(.red).disabled(rec.state != .recording)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct EventChip: View {
    let title: String
    let end: Date
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").foregroundStyle(.red)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text("until \(end.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct PulsingDot: View {
    @ViewState private var on = false
    var body: some View {
        Circle().fill(.red).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

/// The app's mark: an ear on a soft gradient, used in the popover and the empty states.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 1), Color(red: 0.62, green: 0.32, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "ear.badge.waveform").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
