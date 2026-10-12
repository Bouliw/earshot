import AppKit

/// Fictional content for screenshots (`Earshot --demo [--open transcript library]`).
@MainActor
enum Demo {
    static let lines: [(String?, String)] = [
        ("Sarah Mitchell", "Okay, let's pick up where we left off last week. We talked about why most brand content never gets read."),
        ("Sarah Mitchell", "Today I want to look at the other side: the pieces that do travel, and what they have in common."),
        ("David Chen", "Quick question before we start. Are we talking about organic reach only, or paid distribution as well?"),
        ("Sarah Mitchell", "Good question. Organic first. Paid can amplify something that already works, but it rarely rescues something that doesn't."),
        ("Amélie Rousseau", "So in our case study, the newsletter grew mostly through forwards, not through ads?"),
        ("Sarah Mitchell", "Exactly. About seventy percent of new subscribers came from a forward or a share. That's the number I want you to remember."),
        ("Sarah Mitchell", "Now, there are three things these pieces have in common. First, they answer one precise question. Second, they are useful the day you read them."),
        ("David Chen", "And the third one?"),
    ]

    /// `--live`: the last lines are spoken word by word, as in a real session (for the README animation).
    static func play(_ rec: Recorder) {
        let all = rec.segments + [Segment(start: rec.segments.last!.end + 3, end: rec.segments.last!.end + 9, speaker: rec.previewSpeaker, text: rec.preview)]
        rec.segments = Array(all.prefix(6))
        rec.preview = ""
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            for s in all.dropFirst(6) {
                rec.previewSpeaker = s.speaker
                var words: [Substring] = []
                for word in s.text.split(separator: " ") {
                    words.append(word)
                    rec.preview = words.joined(separator: " ")
                    rec.level = .random(in: 0.02...0.15)
                    try? await Task.sleep(for: .milliseconds(150))
                }
                try? await Task.sleep(for: .milliseconds(500))
                rec.preview = ""
                rec.segments.append(s)
            }
        }
    }

    static func fill(_ state: AppState) {
        let teams = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.teams2")
        let icon = teams.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "video", accessibilityDescription: nil)!
        func app(_ name: String, _ bundle: String, _ playing: Bool, _ pid: pid_t) -> AudioApp {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            return AudioApp(pid: pid, bundleID: bundle, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? icon, processes: [], isPlaying: playing)
        }
        state.apps = [
            app("Microsoft Teams", "com.microsoft.teams2", true, 1),
            app("Google Chrome", "com.google.Chrome", true, 2),
            app("Discord", "com.hnc.Discord", false, 3),
            app("Music", "com.apple.Music", false, 4),
        ]
        state.event = ("Content Strategy — Lecture 4", Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: Date())!)

        let rec = state.recorder
        let start = Date().addingTimeInterval(-47 * 60 - 12)
        var t = 120.0
        rec.segments = lines.map { speaker, text in
            defer { t += Double(text.count) / 14 + 4 }
            return Segment(start: t, end: t + Double(text.count) / 14, speaker: speaker, text: text)
        }
        if !CommandLine.arguments.contains("--idle") {
            rec.app = state.apps[0]
            rec.title = "Content Strategy — Lecture 4"
            rec.startedAt = start
            rec.eventEnd = state.event?.end
            rec.state = .recording
            rec.level = 0.05
            rec.preview = "Third, they have a voice. You can tell a person wrote them, not a committee"
            rec.previewSpeaker = "Sarah Mitchell"
            if CommandLine.arguments.contains("--live") { play(rec) }
        }

        let day: TimeInterval = 86_400
        state.library = [
            ("Content Strategy — Lecture 4", "Content Strategy", 0.0, 5_520.0),
            ("Content Strategy — Lecture 3", "Content Strategy", 7 * day, 5_400),
            ("Data & AI for Managers", "Data & AI for Managers", 2 * day, 6_300),
            ("Data & AI for Managers", "Data & AI for Managers", 9 * day, 6_120),
            ("Team sync", "Microsoft Teams", 3 * day, 1_860),
        ].map { title, group, ago, duration in
            var r = SessionRecord(title: title, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                                  startedAt: start.addingTimeInterval(-ago), duration: duration, segments: rec.segments)
            r.folder = URL(filePath: "/tmp/Earshot/\(group)/\(Int(ago))")
            return r
        }
    }
}
