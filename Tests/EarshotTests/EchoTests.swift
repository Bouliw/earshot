import Foundation
import Testing
@testable import Earshot

@Suite struct EchoTests {
    static let rate = 16_000

    /// Speech-like sound: bursts of coloured noise the length of syllables, with short pauses.
    static func voice(seconds: Double, seed: UInt64, pitch: Double) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var output = [Float](repeating: 0, count: Int(seconds * Double(rate)))
        var y1 = 0.0, y2 = 0.0
        let r = 0.97, w = 2 * Double.pi * pitch / Double(rate)
        var i = 0
        while i < output.count {
            let syllable = Int((0.12 + 0.2 * random()) * Double(rate))
            let gap = Int((0.03 + 0.1 * random()) * Double(rate))
            var k = 0
            while k < syllable, i < output.count {
                let y = random() * 2 - 1 + 2 * r * cos(w) * y1 - r * r * y2
                y2 = y1
                y1 = y
                output[i] = Float(y * sin(Double.pi * Double(k) / Double(syllable)))
                k += 1
                i += 1
            }
            i += gap
        }
        let rms = sqrt(output.map { $0 * $0 }.reduce(0, +) / Float(output.count))
        return output.map { $0 * 0.1 / rms }
    }

    /// What a microphone hears of the speakers `delay` samples later, with a few reflections.
    static func room(_ app: [Float], delay: Int, gain: Float = 0.5) -> [Float] {
        let taps: [(at: Int, gain: Float)] = [(0, 1), (37, 0.4), (211, -0.2), (900, 0.1), (2_300, -0.05)]
        var output = [Float](repeating: 0, count: app.count)
        for t in output.indices {
            for tap in taps {
                let from = t - delay - tap.at
                if from >= 0 { output[t] += gain * tap.gain * tanh(1.5 * app[from]) / 1.5 }
            }
        }
        return output
    }

    static func place(_ sound: [Float], at seconds: Double, length: Int) -> [Float] {
        var output = [Float](repeating: 0, count: length)
        let start = Int(seconds * Double(rate))
        for i in 0..<min(sound.count, length - start) { output[start + i] = sound[i] }
        return output
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map(+) }

    static func energy(_ s: [Float], _ from: Double, _ to: Double, minus: [Float]? = nil) -> Double {
        (Int(from * Double(rate))..<Int(to * Double(rate))).reduce(0.0) { sum, i in
            let x = Double(s[i] - (minus?[i] ?? 0))
            return sum + x * x
        }
    }

    static func db(_ ratio: Double) -> Double { 10 * log10(ratio) }

    @Test func theAppsVoiceIsTakenOutOfTheMicrophoneAndTheUsersStays() {
        let length = 20 * Self.rate
        let app = Self.place(Self.voice(seconds: 14, seed: 1, pitch: 600), at: 0, length: length)  // talks for 14 s, then stops
        let user = Self.add(Self.place(Self.voice(seconds: 3, seed: 2, pitch: 1_500), at: 8, length: length),
                            Self.place(Self.voice(seconds: 3, seed: 3, pitch: 1_300), at: 15, length: length))
        let mic = Self.add(Self.room(app, delay: 1_280), user)  // built-in speakers, 80 ms
        let cleaned = EchoCanceller.clean(mic: mic, reference: app)

        // The other side alone: its echo is at least 20 dB down.
        #expect(Self.db(Self.energy(mic, 2, 7) / Self.energy(cleaned, 2, 7)) > 20)
        // Both at once (the user cuts in): the user's voice comes out at least 10 dB clearer than it was recorded.
        #expect(Self.db(Self.energy(mic, 8, 11, minus: user) / Self.energy(cleaned, 8, 11, minus: user)) > 10)
        // The user alone: left as it was.
        #expect(Self.db(Self.energy(user, 15, 18) / Self.energy(cleaned, 15, 18, minus: user)) > 30)
    }

    @Test func withHeadphonesTheMicrophoneIsLeftAsRecorded() {
        let app = Self.voice(seconds: 12, seed: 4, pitch: 700)
        let mic = Self.place(Self.voice(seconds: 4, seed: 5, pitch: 1_400), at: 3, length: app.count)
        #expect(EchoCanceller.clean(mic: mic, reference: app) == mic)
    }

    @Test(arguments: [160, 4_000])  // 10 ms, and 250 ms (a Bluetooth speaker)
    func theDelayOfTheEchoIsFound(delay: Int) {
        let app = Self.voice(seconds: 12, seed: 6, pitch: 800)
        let lags = EchoDelay.track(reference: app, mic: Self.room(app, delay: delay)).map(\.lag)
        #expect(!lags.isEmpty)
        #expect(lags.allSatisfy { abs($0 - delay) <= 8 })
    }

    /// Live, the canceller learns the room as the call goes: after a few seconds the echo is down too.
    @Test func liveTheEchoIsTakenOutAsTheCallGoes() {
        let length = 16 * Self.rate
        let app = Self.place(Self.voice(seconds: 16, seed: 7, pitch: 650), at: 0, length: length)
        let mic = Self.room(app, delay: 1_000)
        let live = LiveEchoCanceller()
        var cleaned: [Float] = []
        var at = 0
        while at < length {
            let n = min(480, length - at)  // 30 ms buffers, as the app's tap sends them
            cleaned += live.process(reference: Array(app[at..<(at + n)]), mic: Array(mic[at..<(at + n)]))
            at += n
        }
        #expect(cleaned.count >= length - LiveEchoCanceller.latency)
        #expect(Self.db(Self.energy(mic, 10, 15) / Self.energy(cleaned, 10, 15)) > 15)
    }

    @Test func theMicrophonesLinesThatRepeatTheOtherSideAtThatMomentAreDropped() {
        let other = Segment(start: 10, end: 14, speaker: "Speaker 1", text: "Lundi on commence par la revue des incidents.")
        let echo = Segment(start: 10.2, end: 13.8, speaker: "Me", text: "lundi, on commence par la revue des incidents", mic: true)
        let cutIn = Segment(start: 11, end: 12.5, speaker: "Me", text: "Attends, je ne suis pas là lundi.", mic: true)
        let later = Segment(start: 30, end: 33, speaker: "Me", text: "Lundi on commence par la revue des incidents.", mic: true)
        #expect(EchoLines.dropping([other, echo, cutIn, later]) == [other, cutIn, later])
    }
}
