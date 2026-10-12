import AVFoundation

/// `Earshot --check`: checks the name and timing logic.
/// `Earshot --transcribe <file> [model]`: streams an audio file through the live pipeline at 4x speed
/// and prints what would appear on screen. Checks the streaming logic without a call.
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
        print("checks passed")
    }

    static func runIfAsked() {
        let args = CommandLine.arguments
        if args.contains("--check") { checks(); exit(0) }
        guard let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count else { return }
        let file = try! AVAudioFile(forReading: URL(filePath: args[i + 1]))
        let model = WhisperModel.preferred(i + 2 < args.count ? args[i + 2] : "")!
        print("model: \(model.name)")
        let pcm = AVAudioPCMBuffer(pcmFormat: AudioTap.outputFormat, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.fileFormat.sampleRate) + 1)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: AudioTap.outputFormat)!
        var fed = false
        converter.convert(to: pcm, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return source
        }
        let samples = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))

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
}
