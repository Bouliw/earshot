import AVFoundation

/// `Earshot --check`: checks the name and timing logic.
/// `Earshot --transcribe <file> [model]`: streams an audio file through the live pipeline at 4x speed
/// and prints what would appear on screen. Checks the streaming logic without a call.
/// `Earshot --subtitles <file> [apple|kyutai]`: plays an audio file through a subtitle engine in real time
/// and prints each line once it is finished.
enum SelfTest {
    static func checks() {
        precondition(TeamsCaptions.displayName("DOE-EXTERNAL Jane") == "Jane Doe")
        precondition(TeamsCaptions.displayName("SMITH John Paul") == "John Paul Smith")
        precondition(TeamsCaptions.displayName("Jane Doe") == "Jane Doe")
        precondition(CalendarLookup.courseName("SCHOOL : Content Strategy - Session 2") == "Content Strategy")
        precondition(CalendarLookup.courseName("Weekly sync") == "Weekly sync")
        var timeline = SpeakerTimeline()
        timeline.add(10, "A"); timeline.add(11, "A"); timeline.add(20, "B")
        precondition(timeline.speaker(from: 8, to: 11) == "A")
        precondition(timeline.speaker(from: 18, to: 20) == "B")
        precondition(timeline.speaker(from: 22, to: 24) == "B")   // nothing new: last speaker still talking
        precondition(timeline.speaker(from: 60, to: 62) == nil)   // too long ago
        precondition(StreamingTranscriber.isNoise("[BLANK_AUDIO]") && !StreamingTranscriber.isNoise("Thank you."))
        let turns = Turn.group([Segment(start: 0, end: 2, speaker: "A", text: "Hi."), Segment(start: 2, end: 4, speaker: "A", text: "Yes."), Segment(start: 4, end: 5, speaker: "B", text: "Ok.")])
        precondition(turns.count == 2 && turns[0].text == "Hi. Yes.")
        let talking = MicMix()
        _ = talking.mixApp([Float](repeating: 0.1, count: 160))
        precondition(talking.gateMic([0.2, 0.2]) == [0, 0])        // app talking: mic muted (echo)
        let quiet = MicMix()
        precondition(quiet.gateMic([0.2, 0.2]) == [0.2, 0.2])
        precondition(quiet.mixApp([0, 0, 0]) == [0.2, 0.2, 0])    // mic lands in the saved audio
        MainActor.assumeIsolated {
            var who: String? = "A"
            let feed = SubtitleFeed()
            feed.speaker = { who }
            for piece in [" Hello", " ", "there.", " Next"] { feed.append(piece) }  // Kyutai can send the space alone
            who = "B"
            feed.append(" one")                                        // a new speaker ends the phrase
            precondition(feed.lines == [.init(speaker: "A", text: "Hello there."), .init(speaker: "A", text: "Next"), .init(speaker: "B", text: "one")])
            let apple = SubtitleFeed()
            apple.update("Good"); apple.update("Good morning"); apple.commit(); apple.update("Today")
            precondition(apple.lines.map(\.text) == ["Good morning", "Today"] && apple.total == 2)
            let shown = SubtitlesView.render([.init(speaker: "A", text: "Hi."), .init(speaker: "A", text: "Yes."), .init(speaker: nil, text: "Ok.")], size: 20)
            precondition(String(shown.characters) == "A  Hi. Yes.\nOk.")
        }
        // Interpolated keys must match the French table (run from the built app, where fr.lproj exists).
        if let path = Bundle.main.path(forResource: "fr", ofType: "lproj"), let fr = Bundle(path: path) {
            let name = "Teams", step = "tap", status = OSStatus(-1)
            precondition(String(localized: "\(name) call", bundle: fr) == "Appel Teams")
            precondition(String(localized: "\(3) speakers", bundle: fr) == "3 intervenants")
            precondition(String(localized: "until \(name)", bundle: fr) == "jusqu'à Teams")
            precondition(String(localized: "Could not capture audio (\(step), error \(status)). Check System Settings › Privacy & Security › Screen & System Audio Recording.", bundle: fr).hasPrefix("Impossible"))
            precondition(String(localized: "Could not load the model \(name).", bundle: fr) == "Impossible de charger le modèle Teams.")
            precondition(String(localized: "Install (\(name))", bundle: fr) == "Installer (Teams)")
            precondition(String(localized: "High subtitles stopped: \(name)", bundle: fr) == "Les sous-titres Élevé se sont arrêtés : Teams")
        }
        print("checks passed")
    }

    static func runIfAsked() {
        let args = CommandLine.arguments
        if args.contains("--check") { checks(); exit(0) }
        if let i = args.firstIndex(of: "--subtitles"), i + 1 < args.count {
            subtitles(samples(args[i + 1]), kind: SubtitleEngineKind(rawValue: i + 2 < args.count ? args[i + 2] : "") ?? .apple)
        }
        guard let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count else { return }
        let model = WhisperModel.preferred(i + 2 < args.count ? args[i + 2] : "")!
        print("model: \(model.name)")
        let samples = samples(args[i + 1])

        let t = StreamingTranscriber(model: model.url, language: "auto")
        let began = Date()
        var previews = 0, lines = 0
        t.onPreview = { if !$0.isEmpty { previews += 1 } }
        t.onCommit = { segs in
            for s in segs { lines += 1; print(String(format: "[%6.1f-%6.1f] (+%.1fs) %@", s.start, s.end, Date().timeIntervalSince(began) * 4 - s.end, s.text)) }
        }
        t.onError = { print("error: \($0)") }
        let chunk = 1_600  // 100 ms
        for start in stride(from: 0, to: samples.count, by: chunk) {
            t.append(Array(samples[start..<min(start + chunk, samples.count)]))
            Thread.sleep(forTimeInterval: 0.025)
        }
        let done = DispatchSemaphore(value: 0)
        t.finish { done.signal() }
        done.wait()
        print("lines: \(lines), live previews: \(previews), audio \(samples.count / 16_000)s in \(Int(Date().timeIntervalSince(began)))s")
        assert(lines > 0, "speech should produce at least one line")
        exit(0)
    }

    private static func subtitles(_ samples: [Float], kind: SubtitleEngineKind) -> Never {
        MainActor.assumeIsolated {
            let feed = SubtitleFeed()
            Task { @MainActor in
                do {
                    let engine: SubtitleEngine = kind == .kyutai ? try KyutaiSubtitles(feed: feed) : try await AppleSubtitles(language: "auto", feed: feed)
                    let began = Date()
                    Thread.detachNewThread {
                        let chunk = 1_600  // 100 ms, then 3 s of silence so the last words come out
                        for start in stride(from: 0, to: samples.count + 48_000, by: chunk) {
                            engine.append(start < samples.count ? Array(samples[start..<min(start + chunk, samples.count)]) : [Float](repeating: 0, count: chunk))
                            Thread.sleep(until: began.addingTimeInterval(Double(start + chunk) / 16_000))
                        }
                    }
                    var printed = 0
                    let end = began.addingTimeInterval(Double(samples.count) / 16_000 + 4)
                    while Date() < end {
                        try await Task.sleep(for: .milliseconds(200))
                        let done = Date() >= end ? feed.total : feed.total - 1  // the last line may still change
                        while printed < done {
                            let line = feed.lines[feed.lines.count - (feed.total - printed)]
                            print(String(format: "[%5.1fs] ", Date().timeIntervalSince(began)) + (line.speaker.map { "\($0): " } ?? "") + line.text)
                            printed += 1
                        }
                    }
                    if let error = feed.error { print("error: \(error)") }
                    engine.stop()
                    exit(printed > 0 ? 0 : 1)
                } catch {
                    print("error: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// An audio file as 16 kHz mono samples.
    private static func samples(_ path: String) -> [Float] {
        let file = try! AVAudioFile(forReading: URL(filePath: path))
        let pcm = AVAudioPCMBuffer(pcmFormat: Resampler.format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.fileFormat.sampleRate) + 1)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: Resampler.format)!
        var fed = false
        converter.convert(to: pcm, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return source
        }
        return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
    }
}
