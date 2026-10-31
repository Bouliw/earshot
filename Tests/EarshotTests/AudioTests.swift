import AVFoundation
import Testing
@testable import Earshot

@Suite struct AudioTests {
    @Test func theMicrophoneJoinsTheSavedAudioAndNeverLagsByMoreThanASecond() {
        let mix = MicMix()
        _ = mix.gateMic([Float](repeating: 0.1, count: 20_000))
        let saved = mix.mixApp([Float](repeating: 0, count: 20_000))
        #expect(saved.prefix(16_000).allSatisfy { abs($0 - 0.1) < 1e-6 })
        #expect(saved.suffix(4_000).allSatisfy { $0 == 0 })
    }

    @Test func quietNoiseFromTheAppDoesNotMuteTheMicrophone() {
        let mix = MicMix()
        _ = mix.mixApp([Float](repeating: 0.005, count: 160))
        #expect(mix.gateMic([0.2, 0.2]) == [0.2, 0.2])
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
