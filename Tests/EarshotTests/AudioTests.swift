import AVFoundation
import Testing
@testable import Earshot

@Suite struct AudioTests {
    @Test func theMicrophoneGoesOnTheAppsClockAndNeverLagsByMoreThanASecond() {
        let mix = MicMix()
        mix.addMic([Float](repeating: 0.1, count: 20_000))
        let (_, mic, _) = mix.split([Float](repeating: 0, count: 20_000))
        #expect(mic.prefix(16_000).allSatisfy { abs($0 - 0.1) < 1e-6 })
        #expect(mic.suffix(4_000).allSatisfy { $0 == 0 })
    }

    /// It used to be muted whenever the app made a sound, and the user's words were lost each time they spoke over
    /// the other side. Now it is kept whole on its own track, and with nothing of the app in it, cleaning it changes
    /// nothing that matters; it goes into the saved audio too.
    @Test func theMicrophoneIsNeverMutedWhileTheAppTalks() {
        let app = EchoTests.voice(seconds: 2, seed: 1, pitch: 700)
        let voice = EchoTests.voice(seconds: 2, seed: 2, pitch: 1_400)
        let mix = MicMix()
        var saved: [Float] = [], mic: [Float] = [], cleaned: [Float] = []
        for at in stride(from: 0, to: app.count, by: 400) {  // 25 ms buffers, as they come
            mix.addMic(Array(voice[at..<(at + 400)]))
            let out = mix.split(Array(app[at..<(at + 400)]))
            saved += out.mix; mic += out.mic; cleaned += out.cleaned
        }
        #expect(Array(mic[MicMix.cushion...]) == Array(voice[..<(voice.count - MicMix.cushion)]))
        let n = cleaned.count
        #expect(n >= mic.count - LiveEchoCanceller.latency)
        let kept = zip(cleaned, mic.prefix(n)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        #expect(10 * log10(mic.prefix(n).map { $0 * $0 }.reduce(0, +) / kept) > 15)
        let shift = LiveEchoCanceller.latency
        #expect(zip(saved[shift...], app[shift...]).contains { abs($0 - $1) > 0.01 })
    }

    @Test func samplesRoundTripThroughABuffer() throws {
        let samples: [Float] = [0, 0.25, -0.5]
        let buffer = try #require(Resampler.buffer(samples))
        #expect(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) == samples)
        #expect(Resampler.buffer([]) == nil)
    }

    /// Whisper wants 16 kHz mono whatever the device runs at (a wrong rate stretches the audio and garbles the transcript),
    /// and a microphone that only feeds one channel must not go silent. Fed as the capture does, in small buffers through
    /// one converter: ten seconds of a 440 Hz tone on the right channel only, in 100 ms pieces.
    @Test(arguments: [16_000.0, 24_000, 44_100, 48_000])
    func anyRateComesOutAsSixteenKilohertzMonoWithoutLosingAChannel(rate: Double) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let resampler = try #require(Resampler(from: format))
        let frames = AVAudioFrameCount(rate / 10)
        var out: [Float] = []
        for piece in 0..<100 {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            input.frameLength = frames
            for i in 0..<Int(frames) {
                input.floatChannelData![0][i] = 0
                input.floatChannelData![1][i] = 0.5 * sin(2 * .pi * 440 * Float(Int(frames) * piece + i) / Float(rate))
            }
            out += resampler(input) ?? []
        }
        #expect(abs(out.count - 160_000) < 4_800, "got \(out.count) samples")
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Float(max(out.count, 1))).squareRoot()
        #expect(rms > 0.1 && rms < 0.5, "the tone should still be heard, got \(rms)")
    }
}
