import Accelerate
import Foundation

/// Takes the app's sound back out of the microphone. With speakers rather than headphones, the microphone also hears
/// the other side of the call, a moment after the Mac plays it. Both tracks are kept whole: the app's track says what
/// the speakers played, an adaptive filter learns how the room carries it to the microphone, and that estimate is taken
/// away, so the user's own voice stays even while the other side is talking (cutting someone off is transcribed too).
/// With headphones there is no echo to find and the microphone is left exactly as recorded.
final class EchoCanceller {
    static let block = 256                       // 16 ms
    private static let size = 2 * block, bins = block + 1
    private static let partitions = 20           // the filter spans 320 ms of the room
    private static let lead = 2 * block          // and starts 32 ms before the strongest echo
    private static let step: Float = 0.5
    private static let floor = Float(size * partitions) * 1e-6  // an app sound under -60 dBFS teaches the filter nothing
    private static let warmUpSeconds = 60.0
    private static let constrain = 4

    /// Fills `count` samples of the app's sound from sample `start` on (silence outside what was recorded).
    typealias Reader = (_ start: Int, _ into: UnsafeMutablePointer<Float>, _ count: Int) -> Void

    private let readReference: Reader
    private let fft = FFT(size)
    private let memory: UnsafeMutablePointer<Float>
    private let workRe, workIm, time: UnsafeMutablePointer<Float>
    // Spectra of the app's sound, one per block, kept by block number modulo the number of partitions.
    private let xRe, xIm: UnsafeMutablePointer<Float>
    private var xBlock = [Int](repeating: .min, count: partitions)
    private var xEnergy = [Double](repeating: 0, count: partitions)
    // Two filters: the background one learns all the time, the foreground one (the one heard) only takes what the
    // background learned once it does better. While both people talk the background goes astray; the output does not.
    private let fgRe, fgIm, bgRe, bgIm: UnsafeMutablePointer<Float>
    private let spanPower, yRe, yIm, eRe, eIm, gRe, gIm: UnsafeMutablePointer<Float>
    private let echoFg, errorFg, echoBg, errorBg: UnsafeMutablePointer<Float>
    private var energyMic = 0.0, energyFg = 0.0, energyBg = 0.0
    private var offset: Int?
    private var lastLag: Int?
    // What the filter leaves (speakers that distort, a room that changes) is turned down where it is louder than the voice.
    private let window, lastError, lastEcho, tail: UnsafeMutablePointer<Float>
    private let pRe, pIm, qRe, qIm, errorAvg, echoAvg, residual, gain: UnsafeMutablePointer<Float>
    private var pey = 0.0, pyy = 0.0
    private var leak: Float = 0.25
    private let output: UnsafeMutablePointer<Float>

    init(readReference: @escaping Reader) {
        self.readReference = readReference
        let size = Self.size, bins = Self.bins, block = Self.block, spectra = Self.partitions * Self.bins
        let total = 4 * size + 6 * spectra + 15 * bins + 8 * block
        let base = UnsafeMutablePointer<Float>.allocate(capacity: total)
        base.initialize(repeating: 0, count: total)
        var at = 0
        func take(_ n: Int) -> UnsafeMutablePointer<Float> { defer { at += n }; return base + at }
        memory = base
        workRe = take(size); workIm = take(size); time = take(size)
        xRe = take(spectra); xIm = take(spectra)
        fgRe = take(spectra); fgIm = take(spectra); bgRe = take(spectra); bgIm = take(spectra)
        spanPower = take(bins); yRe = take(bins); yIm = take(bins); eRe = take(bins); eIm = take(bins); gRe = take(bins); gIm = take(bins)
        echoFg = take(block); errorFg = take(block); echoBg = take(block); errorBg = take(block)
        window = take(size); lastError = take(block); lastEcho = take(block); tail = take(block)
        pRe = take(bins); pIm = take(bins); qRe = take(bins); qIm = take(bins)
        errorAvg = take(bins); echoAvg = take(bins); residual = take(bins); gain = take(bins)
        output = take(block)
        precondition(at <= total)
        for i in 0..<size { window[i] = Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(size)))) }
        gain.update(repeating: 1, count: bins)
    }

    deinit { memory.deallocate() }

    /// The microphone with the app's sound taken out. `reference` is the app's track, on the same clock. Returns `mic`
    /// itself when no echo of the app is found in it (headphones).
    static func clean(mic: [Float], reference: [Float]) -> [Float] {
        guard !mic.isEmpty, !reference.isEmpty else { return mic }
        let track = EchoDelay.track(reference: reference, mic: mic)
        guard !track.isEmpty else { return mic }
        return reference.withUnsafeBufferPointer { ref in
            mic.withUnsafeBufferPointer { m in
                let canceller = EchoCanceller { start, into, count in
                    into.update(repeating: 0, count: count)
                    let from = max(0, start), to = min(ref.count, start + count)
                    if to > from { (into + (from - start)).update(from: ref.baseAddress! + from, count: to - from) }
                }
                let blocks = (m.count + block - 1) / block
                let samples = UnsafeMutablePointer<Float>.allocate(capacity: block)
                defer { samples.deallocate() }
                var next = 0
                func lag(at b: Int) -> Int {
                    let t = b * block
                    while next + 1 < track.count, abs(track[next + 1].sample - t) <= abs(track[next].sample - t) { next += 1 }
                    return track[next].lag
                }
                func fill(_ b: Int) {
                    samples.update(repeating: 0, count: block)
                    let from = b * block
                    if from < m.count { samples.update(from: m.baseAddress! + from, count: min(block, m.count - from)) }
                }

                // A first look at the start, so the opening sentences are cleaned as well as the rest.
                let warm = min(blocks, Int(warmUpSeconds * Chunker.rate) / block)
                for b in 0..<warm { fill(b); _ = canceller.process(samples, index: b, lag: lag(at: b)) }
                canceller.restart()
                next = 0

                var cleaned = [Float](repeating: 0, count: m.count)
                cleaned.withUnsafeMutableBufferPointer { out in
                    for b in 0...blocks {  // one more block: the post-filter hands each block back one block later
                        fill(b)
                        let done = canceller.process(samples, index: b, lag: lag(at: b))
                        guard b > 0 else { continue }
                        let at = (b - 1) * block
                        (out.baseAddress! + at).update(from: done, count: min(block, m.count - at))
                    }
                }
                return cleaned
            }
        }
    }

    /// Takes block `index` of the microphone (`block` samples) and returns the cleaned block before it (valid until
    /// the next call). `lag`: how many samples after the app plays a sound the microphone hears it, nil while it is
    /// not known yet (the filter then covers the first 300 ms).
    func process(_ mic: UnsafePointer<Float>, index: Int, lag: Int?) -> UnsafePointer<Float> {
        let block = Self.block, partitions = Self.partitions
        align(lag)
        let r = index - offset! / block
        var span = 0.0
        for k in 0..<partitions { span += reference(r - k) }
        estimate(fgRe, fgIm, r, into: echoFg)
        estimate(bgRe, bgIm, r, into: echoBg)
        var d = 0.0, f = 0.0, g = 0.0
        for i in 0..<block {
            errorFg[i] = mic[i] - echoFg[i]
            errorBg[i] = mic[i] - echoBg[i]
            d += Double(mic[i] * mic[i])
            f += Double(errorFg[i] * errorFg[i])
            g += Double(errorBg[i] * errorBg[i])
        }
        energyMic = 0.8 * energyMic + 0.2 * d
        energyFg = 0.8 * energyFg + 0.2 * f
        energyBg = 0.8 * energyBg + 0.2 * g
        if span > Double(Self.floor / 2) {
            adapt(r)
            if energyBg < 0.8 * energyFg, energyBg < energyMic {
                fgRe.update(from: bgRe, count: partitions * Self.bins)
                fgIm.update(from: bgIm, count: partitions * Self.bins)
                energyFg = energyBg
            } else if energyBg > 4 * energyMic, energyBg > 4 * energyFg {
                bgRe.update(from: fgRe, count: partitions * Self.bins)
                bgIm.update(from: fgIm, count: partitions * Self.bins)
                energyBg = energyFg
            }
        }
        return UnsafePointer(postFilter())
    }

    /// Starts a new pass over the recording, keeping what was learned about the room.
    func restart() {
        for p in [lastError, lastEcho, tail] { p.update(repeating: 0, count: Self.block) }
        residual.update(repeating: 0, count: Self.bins)
        gain.update(repeating: 1, count: Self.bins)
    }

    /// Moves the filter when the echo comes noticeably earlier or later (a Bluetooth headset, clocks drifting).
    private func align(_ estimate: Int?) {
        let block = Self.block, lag = estimate ?? 0
        let target = Int((Double(lag - Self.lead) / Double(block)).rounded(.down)) * block
        guard let current = offset else { offset = target; lastLag = estimate; return }
        let jump = lastLag.map { lag - $0 } ?? 0  // the first delay found is where the echo always was
        lastLag = estimate ?? lastLag
        let into = lag - current
        let moveFrame = into < block || into >= 4 * block
        // Under 16 ms it is the estimate hesitating between the direct sound and a reflection: the filter covers both.
        let jumped = abs(jump) > block
        guard moveFrame || jumped else { return }
        let next = moveFrame ? target : current
        // What was learned about the room stays. When the echo drifted slowly, the filter followed it and only the
        // frame moves; when it jumped (a headset reconnected), the filter jumps with it.
        let shift = next - current - (jumped ? jump : 0)
        if shift != 0 {
            shiftTaps(fgRe, fgIm, by: shift)
            shiftTaps(bgRe, bgIm, by: shift)
        }
        offset = next
    }

    /// The filter, as one impulse response, moved `samples` earlier.
    private func shiftTaps(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, by samples: Int) {
        let block = Self.block, bins = Self.bins, partitions = Self.partitions
        var taps = [Float](repeating: 0, count: partitions * block)
        for k in 0..<partitions {
            toTime(re + k * bins, im + k * bins, time)
            for i in 0..<block { taps[k * block + i] = time[i] }
        }
        for k in 0..<partitions {
            time.update(repeating: 0, count: Self.size)
            for i in 0..<block {
                let from = k * block + i + samples
                if from >= 0, from < taps.count { time[i] = taps[from] }
            }
            toSpectrum(time, re + k * bins, im + k * bins)
        }
    }

    private static func slot(_ block: Int) -> Int { ((block % partitions) + partitions) % partitions }

    private func reference(_ block: Int) -> Double {
        let slot = Self.slot(block)
        if xBlock[slot] == block { return xEnergy[slot] }
        readReference((block - 1) * Self.block, time, Self.size)
        var energy = 0.0
        for i in Self.block..<Self.size { energy += Double(time[i] * time[i]) }
        toSpectrum(time, xRe + slot * Self.bins, xIm + slot * Self.bins)
        xBlock[slot] = block
        xEnergy[slot] = energy
        return energy
    }

    private func estimate(_ wRe: UnsafeMutablePointer<Float>, _ wIm: UnsafeMutablePointer<Float>, _ r: Int, into echo: UnsafeMutablePointer<Float>) {
        let bins = Self.bins
        yRe.update(repeating: 0, count: bins)
        yIm.update(repeating: 0, count: bins)
        for k in 0..<Self.partitions {
            let s = Self.slot(r - k)
            let ar = wRe + k * bins, ai = wIm + k * bins, br = xRe + s * bins, bi = xIm + s * bins
            for j in 0..<bins {
                yRe[j] += ar[j] * br[j] - ai[j] * bi[j]
                yIm[j] += ar[j] * bi[j] + ai[j] * br[j]
            }
        }
        toTime(yRe, yIm, time)
        echo.update(from: time + Self.block, count: Self.block)
    }

    /// One step of the background filter (partitioned frequency-domain NLMS, normalized by the app's power).
    private func adapt(_ r: Int) {
        let block = Self.block, bins = Self.bins
        time.update(repeating: 0, count: block)
        (time + block).update(from: errorBg, count: block)
        toSpectrum(time, eRe, eIm)
        gRe.update(repeating: 0, count: bins)
        for k in 0..<Self.partitions {
            let s = Self.slot(r - k)
            let xr = xRe + s * bins, xi = xIm + s * bins
            for j in 0..<bins { gRe[j] += xr[j] * xr[j] + xi[j] * xi[j] }
        }
        for j in 0..<bins { spanPower[j] = 0.5 * spanPower[j] + 0.5 * gRe[j] }
        for k in 0..<Self.partitions {
            let s = Self.slot(r - k)
            let xr = xRe + s * bins, xi = xIm + s * bins
            for j in 0..<bins {
                let mu = Self.step / (spanPower[j] + Self.floor)
                gRe[j] = mu * (xr[j] * eRe[j] + xi[j] * eIm[j])
                gIm[j] = mu * (xr[j] * eIm[j] - xi[j] * eRe[j])
            }
            let wr = bgRe + k * bins, wi = bgIm + k * bins
            for j in 0..<bins { wr[j] += gRe[j]; wi[j] += gIm[j] }
            // Only the first half of the taps is a filter of one block: the rest would wrap around. Trimmed on a
            // quarter of the partitions each block, in turn (four times faster, and the filter learns as well).
            guard Self.slot(r + k) % Self.constrain == 0 else { continue }
            toTime(wr, wi, time)
            (time + block).update(repeating: 0, count: block)
            toSpectrum(time, wr, wi)
        }
    }

    /// Turns down, frequency by frequency, what is left of the echo where it is louder than the user's voice.
    /// How much is left is measured as it goes: the part of the output that rises and falls with the echo estimate.
    private func postFilter() -> UnsafeMutablePointer<Float> {
        let block = Self.block, bins = Self.bins
        for i in 0..<block {
            time[i] = lastError[i] * window[i]
            time[i + block] = errorFg[i] * window[i + block]
        }
        toSpectrum(time, pRe, pIm)
        for i in 0..<block {
            time[i] = lastEcho[i] * window[i]
            time[i + block] = echoFg[i] * window[i + block]
        }
        toSpectrum(time, qRe, qIm)
        lastError.update(from: errorFg, count: block)
        lastEcho.update(from: echoFg, count: block)

        var echoTotal = 0.0
        for j in 0..<bins { echoTotal += Double(qRe[j] * qRe[j] + qIm[j] * qIm[j]) }
        if echoTotal > 1e-3 {
            var covariance = 0.0, variance = 0.0
            for j in 0..<bins {
                let ep = pRe[j] * pRe[j] + pIm[j] * pIm[j], yp = qRe[j] * qRe[j] + qIm[j] * qIm[j]
                errorAvg[j] = 0.9 * errorAvg[j] + 0.1 * ep
                echoAvg[j] = 0.9 * echoAvg[j] + 0.1 * yp
                let de = Double(ep - errorAvg[j]), dy = Double(yp - echoAvg[j])
                covariance += de * dy
                variance += dy * dy
            }
            pey = 0.95 * pey + 0.05 * covariance
            pyy = 0.95 * pyy + 0.05 * variance
            if pyy > 0 { leak = Float(min(0.5, max(0.005, pey / pyy))) }
        }
        for j in 0..<bins {
            let ep = pRe[j] * pRe[j] + pIm[j] * pIm[j], yp = qRe[j] * qRe[j] + qIm[j] * qIm[j]
            residual[j] = max(leak * yp, 0.7 * residual[j])
            let g = min(1, max(0.1, 1 - 2 * residual[j] / (ep + 1e-12)))
            gain[j] = max(g, 0.6 * gain[j])
            pRe[j] *= gain[j]
            pIm[j] *= gain[j]
        }
        toTime(pRe, pIm, time)
        for i in 0..<block {
            output[i] = tail[i] + time[i] * window[i]
            tail[i] = time[i + block] * window[i + block]
        }
        return output
    }

    private func toSpectrum(_ samples: UnsafePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        workRe.update(from: samples, count: Self.size)
        workIm.update(repeating: 0, count: Self.size)
        fft.forward(workRe, workIm)
        re.update(from: workRe, count: Self.bins)
        im.update(from: workIm, count: Self.bins)
    }

    private func toTime(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, _ samples: UnsafeMutablePointer<Float>) {
        let size = Self.size, bins = Self.bins
        workRe.update(from: re, count: bins)
        workIm.update(from: im, count: bins)
        workIm[0] = 0
        workIm[Self.block] = 0
        for j in bins..<size { workRe[j] = re[size - j]; workIm[j] = -im[size - j] }
        fft.inverse(workRe, workIm)
        samples.update(from: workRe, count: size)
    }
}

/// The canceller fed as the sound comes, for live transcription and the saved audio: the app's sound and the
/// microphone on the same clock, a buffer at a time. The cleaned microphone comes out `latency` samples later.
final class LiveEchoCanceller {
    /// Samples between a microphone sample going in and its cleaned version coming out.
    static let latency = 5 * EchoCanceller.block
    private static let keep = 8 * 16_000
    private static let every = 16_000  // a new look at the delay each second

    private var reference: [Float] = []
    private var mic: [Float] = []
    private var base = 0                   // sample number of reference[0] and mic[0]
    private var next = 0                   // next microphone block to clean
    private var lag: Int?
    private var candidate: Int?
    private var sinceLook = 0
    private let fft = FFT(EchoDelay.size)
    private lazy var canceller = EchoCanceller { [unowned self] start, into, count in
        into.update(repeating: 0, count: count)
        let from = max(start, self.base), to = min(start + count, self.base + self.reference.count)
        guard to > from else { return }
        self.reference.withUnsafeBufferPointer { (into + (from - start)).update(from: $0.baseAddress! + (from - self.base), count: to - from) }
    }

    /// The app's sound and as many microphone samples, on the app's clock. Returns the cleaned microphone so far.
    func process(reference app: [Float], mic samples: [Float]) -> [Float] {
        reference += app
        mic += samples
        sinceLook += app.count
        if sinceLook >= Self.every { sinceLook = 0; look() }
        let block = EchoCanceller.block
        var cleaned: [Float] = []
        // The filter may reach 32 ms ahead in the app's sound (two blocks), plus the block itself.
        while (next + 1) * block <= base + mic.count, (next + 3) * block <= base + reference.count {
            let done = mic.withUnsafeBufferPointer { canceller.process($0.baseAddress! + (next * block - base), index: next, lag: lag) }
            if next > 0 { cleaned += UnsafeBufferPointer(start: done, count: block) }
            next += 1
        }
        let drop = min(reference.count, mic.count) - Self.keep
        if drop > Self.keep / 4 {
            reference.removeFirst(drop)
            mic.removeFirst(drop)
            base += drop
        }
        return cleaned
    }

    /// The delay over the last few seconds, taken once two looks in a row agree.
    private func look() {
        let window = EchoDelay.window, before = EchoDelay.before, after = EchoDelay.after, factor = EchoDelay.factor
        let end = (base + min(reference.count, mic.count)) / factor
        let start = end - after - window - before
        guard start * factor >= base else { return }
        let from = start * factor - base
        let ref = EchoDelay.decimate(Array(reference[from..<(from + (before + window) * factor)]))
        let heard = EchoDelay.decimate(Array(mic[from..<(from + (before + window + after) * factor)]))
        guard let found = EchoDelay.estimate(fft, reference: ref, start: before, length: window, mic: heard),
              found.confidence >= EchoDelay.minConfidence else { return }
        let lagNow = max(0, found.lag)
        if let candidate, abs(candidate - lagNow) <= EchoCanceller.block {
            if lag == nil || abs(lag! - lagNow) > 8 { lag = lagNow }
        }
        candidate = lagNow
    }
}

/// How long after the app plays a sound the microphone hears it: from a few milliseconds (built-in speakers) to a
/// few hundred (Bluetooth), and it can drift over a long call. Found by cross-correlating the two tracks, whitened
/// (GCC-PHAT) so the room's reverberation does not blur the peak, on 4 s windows every 2 s.
enum EchoDelay {
    static let factor = 4, rate = 16_000 / 4       // 4 kHz is plenty to find a delay
    static let window = 16_384                     // 4.1 s
    static let before = rate / 25                  // 40 ms: the two clocks may put the echo a little early
    static let after = rate * 6 / 5                // 1.2 s
    static let size = 32_768
    /// How far the correlation peak must stand above the rest. Without an echo (headphones) it stays near 4.
    static let minConfidence: Float = 8

    /// Where an echo was found: at `sample` of the recording (16 kHz), the microphone hears the app `lag` samples
    /// late. Empty when the microphone never hears the app.
    static func track(reference: [Float], mic: [Float]) -> [(sample: Int, lag: Int)] {
        let r = decimate(reference), m = decimate(mic)
        let length = min(window, r.count)
        guard length >= rate else { return [] }
        let fft = FFT(size)
        var estimates: [(sample: Int, lag: Int, confidence: Float)] = []
        var start = 0
        while start + length <= r.count {
            if let e = estimate(fft, reference: r, start: start, length: length, mic: m), e.confidence >= minConfidence {
                estimates.append(((start + length / 2) * factor, e.lag, e.confidence))
            }
            start += length / 2
        }
        // Noise can stand out once by chance; an echo shows again at about the same delay (or very clearly).
        let found = estimates.enumerated().filter { i, e in
            e.confidence >= 2 * minConfidence
                || estimates.enumerated().contains { j, o in j != i && abs(o.lag - e.lag) <= EchoCanceller.block }
        }.map { (sample: $0.element.sample, lag: $0.element.lag) }
        // A lone estimate far from its neighbours is noise: each one becomes the median of three, and the first and
        // last take their neighbour's. A real change of delay shows in two estimates in a row.
        return found.indices.map { i in
            var lag = found[i].lag
            if found.count >= 3 {
                if i == 0 || i == found.count - 1 {
                    let neighbour = found[i == 0 ? 1 : i - 1].lag
                    if abs(lag - neighbour) > EchoCanceller.block { lag = neighbour }
                } else {
                    lag = [found[i - 1].lag, lag, found[i + 1].lag].sorted()[1]
                }
            }
            return (found[i].sample, lag)
        }
    }

    /// The lag (in 16 kHz samples) of the echo of `reference[start ..< start + length]` in `mic` (both at 4 kHz, on
    /// the same sample numbers), and how clearly it stands out. Nil when the app is quiet there.
    static func estimate(_ fft: FFT, reference: [Float], start: Int, length: Int, mic: [Float]) -> (lag: Int, confidence: Float)? {
        // The app must be talking for a good part of the window, or there is nothing to find.
        let frame = rate / 10, frames = length / frame
        var active = 0
        for f in 0..<frames where Chunker.rms(reference[(start + f * frame)..<(start + (f + 1) * frame)]) > 0.003 { active += 1 }
        guard frames > 0, active * 5 >= frames else { return nil }

        var aRe = [Float](repeating: 0, count: size), aIm = [Float](repeating: 0, count: size)
        var bRe = [Float](repeating: 0, count: size), bIm = [Float](repeating: 0, count: size)
        for i in 0..<length { aRe[i] = reference[start + i] }
        var micEnergy = 0.0
        for i in 0..<(length + before + after) {
            let at = start - before + i
            guard at >= 0, at < mic.count else { continue }
            bRe[i] = mic[at]
            micEnergy += Double(mic[at] * mic[at])
        }
        guard micEnergy >= 1e-8 * Double(length) else { return nil }
        aRe.withUnsafeMutableBufferPointer { ar in aIm.withUnsafeMutableBufferPointer { ai in fft.forward(ar.baseAddress!, ai.baseAddress!) } }
        bRe.withUnsafeMutableBufferPointer { br in bIm.withUnsafeMutableBufferPointer { bi in fft.forward(br.baseAddress!, bi.baseAddress!) } }
        let low = Int(150.0 * Double(size) / Double(rate)), high = Int(1900.0 * Double(size) / Double(rate))
        for k in 0...(size / 2) {
            var zr: Float = 0, zi: Float = 0
            if k >= low, k <= high {
                // conj(reference) × microphone, whitened (β-PHAT)
                zr = aRe[k] * bRe[k] + aIm[k] * bIm[k]
                zi = aRe[k] * bIm[k] - aIm[k] * bRe[k]
                let weight = 1 / (pow(zr * zr + zi * zi, 0.4) + 1e-20)
                zr *= weight
                zi *= weight
            }
            aRe[k] = zr
            aIm[k] = zi
            if k > 0, k < size / 2 { aRe[size - k] = zr; aIm[size - k] = -zi }
        }
        aRe.withUnsafeMutableBufferPointer { ar in aIm.withUnsafeMutableBufferPointer { ai in fft.inverse(ar.baseAddress!, ai.baseAddress!) } }
        let span = before + after
        var best = 0
        var sum = 0.0
        for i in 0...span {
            sum += Double(aRe[i] * aRe[i])
            if aRe[i] > aRe[best] { best = i }
        }
        let rms = (sum / Double(span + 1)).squareRoot()
        guard rms > 0 else { return nil }
        // Between two samples at 4 kHz: the top of the parabola through the peak and its neighbours.
        var between = 0.0
        if best > 0, best < span {
            let a = Double(aRe[best - 1]), b = Double(aRe[best]), c = Double(aRe[best + 1]), curve = a - 2 * b + c
            if curve < 0 { between = min(0.5, max(-0.5, 0.5 * (a - c) / curve)) }
        }
        return (Int(((Double(best - before) + between) * Double(factor)).rounded()), Float(Double(aRe[best]) / rms))
    }

    /// 16 kHz to 4 kHz, averaging each four samples.
    static func decimate(_ samples: [Float]) -> [Float] {
        (0..<(samples.count / factor)).map { i in
            (samples[factor * i] + samples[factor * i + 1] + samples[factor * i + 2] + samples[factor * i + 3]) / Float(factor)
        }
    }
}

/// A last guard against echo: a line on the microphone whose words the other side said at that very moment was the
/// speakers, not the user. A line keeps its place unless 70 % of its words were in the other side's lines then.
enum EchoLines {
    private static let slack: TimeInterval = 0.6

    static func dropping(_ segments: [Segment]) -> [Segment] {
        let others = segments.filter { $0.mic != true }
        guard !others.isEmpty else { return segments }
        return segments.filter { $0.mic != true || !isEcho($0, others: others) }
    }

    static func isEcho(_ line: Segment, others: [Segment]) -> Bool {
        let words = self.words(line.text)
        guard !words.isEmpty else { return false }
        var heard: [String: Int] = [:]
        for other in others where other.start < line.end + slack && other.end > line.start - slack {
            for w in self.words(other.text) { heard[w, default: 0] += 1 }
        }
        guard !heard.isEmpty else { return false }
        var found = 0
        for w in words {
            guard let n = heard[w], n > 0 else { continue }
            heard[w] = n - 1
            found += 1
        }
        return found * 10 >= words.count * 7
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}

/// The microphone while the other side talks. What it hears then is either the user (cutting in, a quick "yes") or the
/// call itself: a faint copy through headphones, or what the echo canceller leaves. Whisper turns that copy into lines
/// nobody said, close to the other side's words but not close enough for `EchoLines`. Two signs give it away: it is much
/// quieter than the user's own voice, and its loudness follows the call's, syllable by syllable, a moment later. A
/// stretch heard over the call is kept unless it shows one of them: the user cutting in speaks at their usual level,
/// with a rhythm of their own.
enum EchoLeak {
    static let frame = 320                          // 20 ms
    private static let latest = 60, earliest = -2   // heard up to 1.2 s after the app plays it (Bluetooth), or 40 ms before
    /// A stretch whose loudest second stays under this share of the user's usual level is the call (about -9 dB).
    static let quietShare: Float = 0.35
    /// A stretch whose loudness follows the call's at least this closely (correlation) is the call.
    static let followShare: Float = 0.6

    /// The pieces of the microphone (`mic`, on the app's clock) worth transcribing, given the app's track.
    static func keeping(_ pieces: [Chunker.Piece], mic: [Float], reference: [Float]) -> [Chunker.Piece] {
        guard !pieces.isEmpty, !mic.isEmpty, !reference.isEmpty else { return pieces }
        let m = envelope(mic), r = envelope(reference)
        let sounding = r.filter { $0 > 1e-4 }.sorted()
        guard !sounding.isEmpty else { return pieces }
        let talking = sounding[sounding.count * 9 / 10] / 10  // within 20 dB of the call's loud moments
        // Whether the microphone may be hearing the call at each 20 ms: it talked in the last 1.2 s.
        var heard = [Bool](repeating: false, count: m.count)
        var lastOn = Int.min / 2
        for i in 0..<m.count {
            if i < r.count, r[i] > talking { lastOn = i }
            heard[i] = i - lastOn <= latest
        }
        func frames(_ p: Chunker.Piece) -> Range<Int> {
            let a = max(0, Int(p.start * Chunker.rate) / frame), b = min(m.count, Int(p.end * Chunker.rate) / frame)
            return a..<max(a, b)
        }
        func overCall(_ p: Chunker.Piece) -> Bool {
            let f = frames(p)
            guard !f.isEmpty else { return false }
            return f.filter { heard[$0] }.count * 10 >= f.count * 3
        }
        // The user's usual level: the loudest second of what the microphone heard while the call was quiet.
        let alone = pieces.filter { !overCall($0) }.map { loudest(m, frames($0)) }.sorted()
        let usual: Float? = alone.count >= 3 ? alone[alone.count / 2] : nil
        // How late the microphone hears the call, over the whole recording; each piece is then only checked around it.
        let lag = delay(m, r, talking: talking)
        let lags = max(earliest, lag - 5)...min(latest, lag + 5)
        return pieces.filter { p in
            guard overCall(p) else { return true }
            let f = frames(p)
            if let usual, loudest(m, f) < usual * quietShare { return false }
            return follows(m, r, f, talking: talking, lags: lags) < followShare
        }
    }

    /// The delay (in 20 ms) at which the microphone's loudness follows the call's best, over the whole recording.
    static func delay(_ m: [Float], _ r: [Float], talking: Float) -> Int {
        var best = 0, bestScore: Float = -2
        for lag in earliest...latest {
            let score = follows(m, r, 0..<m.count, talking: talking, lags: lag...lag)
            if score > bestScore { bestScore = score; best = lag }
        }
        return best
    }

    /// Loudness of each 20 ms.
    static func envelope(_ s: [Float]) -> [Float] {
        stride(from: 0, to: s.count, by: frame).map { Chunker.rms(s[$0..<min($0 + frame, s.count)]) }
    }

    /// The loudest second of `f` (all of it when shorter).
    static func loudest(_ e: [Float], _ f: Range<Int>) -> Float {
        guard !f.isEmpty else { return 0 }
        let n = min(50, f.count)
        var sum: Float = 0, best: Float = 0
        for i in f {
            sum += e[i] * e[i]
            if i - n >= f.lowerBound { sum -= e[i - n] * e[i - n] }
            if i - f.lowerBound + 1 >= n { best = max(best, sum) }
        }
        return sqrt(max(best, 0) / Float(n))
    }

    /// How closely the loudness of `f` follows the call's at the best of `lags` (in 20 ms), from -1 to 1, counted only
    /// where the call is talking (a reply that starts as the other side stops does not count) and over half a second at
    /// least (a shorter overlap tells nothing: 0).
    static func follows(_ m: [Float], _ r: [Float], _ f: Range<Int>, talking: Float, lags: ClosedRange<Int>) -> Float {
        var best: Float = 0
        var x: [Float] = [], y: [Float] = []
        x.reserveCapacity(f.count); y.reserveCapacity(f.count)
        for lag in lags {
            x.removeAll(keepingCapacity: true); y.removeAll(keepingCapacity: true)
            for i in f {
                let j = i - lag
                guard j >= 0, j < r.count, r[j] > talking else { continue }
                x.append(log10(m[i] + 1e-4)); y.append(log10(r[j] + 1e-4))
            }
            guard x.count >= 25 else { continue }  // half a second at least
            best = max(best, correlation(x, y))
        }
        return best
    }

    static func correlation(_ x: [Float], _ y: [Float]) -> Float {
        let n = Float(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in x.indices {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / sqrt(sxx * syy)
    }
}

/// Radix-2 fast Fourier transform (Accelerate), in place on separate real and imaginary parts. The forward
/// transform is not scaled; the inverse divides by the size.
final class FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(_ size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "The size must be a power of two.")
        self.size = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    func inverse(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        var scale = 1 / Float(size)
        vDSP_vsmul(re, 1, &scale, re, 1, vDSP_Length(size))
        vDSP_vsmul(im, 1, &scale, im, 1, vDSP_Length(size))
    }
}
