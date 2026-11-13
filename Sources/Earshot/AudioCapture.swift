import AppKit
import AVFoundation
import CoreAudio

// MARK: - Core Audio helpers

private let systemObject = AudioObjectID(kAudioObjectSystemObject)

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
    return status == noErr ? value as String : ""
}

private func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T {
    var a = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
    return value
}

private func audioProcessObjects() -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size)
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &list)
    return list
}

/// Private but long-standing libsystem call: maps a helper process (Chrome renderer, WebKit GPU process,
/// Teams helper...) to the app the user actually sees.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t

// MARK: - Apps that use audio

struct AudioApp: Identifiable, Hashable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage
    var processes: [AudioObjectID]
    var isPlaying: Bool
    var id: pid_t { pid }

    /// Every regular app that owns at least one Core Audio process, playing ones first.
    static func all() -> [AudioApp] {
        var apps: [pid_t: AudioApp] = [:]
        for object in audioProcessObjects() {
            let pid: pid_t = scalarProperty(object, kAudioProcessPropertyPID, 0)
            // Command-line tools (no bundle ID) would show up as their terminal; skip them.
            guard pid > 0, pid != getpid(), !stringProperty(object, kAudioProcessPropertyBundleID).isEmpty else { continue }
            let owner = NSRunningApplication(processIdentifier: responsiblePID(pid)) ?? NSRunningApplication(processIdentifier: pid)
            guard let owner, owner.activationPolicy == .regular, owner.processIdentifier != getpid() else { continue }
            let playing = scalarProperty(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
            if apps[owner.processIdentifier] == nil {
                apps[owner.processIdentifier] = AudioApp(
                    pid: owner.processIdentifier,
                    bundleID: owner.bundleIdentifier ?? "",
                    name: owner.localizedName ?? "App",
                    icon: owner.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!,
                    processes: [], isPlaying: false)
            }
            apps[owner.processIdentifier]!.processes.append(object)
            apps[owner.processIdentifier]!.isPlaying = apps[owner.processIdentifier]!.isPlaying || playing
        }
        return apps.values.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    /// Fresh state of this app (nil once it has quit or released all its audio).
    func refreshed() -> AudioApp? { AudioApp.all().first { $0.pid == pid } }
}

// MARK: - Per-app capture

/// Captures only the sound an app plays, with a Core Audio process tap (macOS 14.2+).
/// Works with the Mac muted. Delivers 16 kHz mono float samples.
final class AudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let description: CATapDescription
    private let queue = DispatchQueue(label: "earshot.audio")

    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case let .coreAudio(step, status): String(localized: "Could not capture audio (\(step), error \(status)). Check System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
        }
    }

    init(processes: [AudioObjectID], onSamples: @escaping ([Float]) -> Void) throws {
        description = CATapDescription(monoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.name = "Earshot"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.coreAudio("tap", status) }

        var asbd: AudioStreamBasicDescription = scalarProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())

        let outputDevice: AudioObjectID = scalarProperty(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
        let outputUID = stringProperty(outputDevice, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earshot",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { AudioHardwareDestroyProcessTap(tapID); throw Failure.coreAudio("aggregate device", status) }

        // The aggregate device runs at its main sub-device's rate, which can differ from the rate the tap
        // reports (a Bluetooth headset in call mode next to 48 kHz speakers, for instance). Reading the
        // samples at the tap's rate then stretches the audio and garbles the transcript, so use the device's.
        let deviceRate: Float64 = scalarProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))
        if deviceRate > 0 { asbd.mSampleRate = deviceRate }
        let format = AVAudioFormat(streamDescription: &asbd) ?? AVAudioFormat(standardFormatWithSampleRate: deviceRate > 0 ? deviceRate : 48_000, channels: 1)!
        let resample = Resampler(from: format)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            if let samples = resample?(buffer) { onSamples(samples) }
        }
        guard status == noErr else { stop(); throw Failure.coreAudio("IO proc", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw Failure.coreAudio("start", status) }
    }

    /// Follows the app when it adds or drops audio processes during a call.
    func update(processes: [AudioObjectID]) {
        description.processes = processes
        var a = address(kAudioTapPropertyDescription)
        var d = description
        AudioObjectSetPropertyData(tapID, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &d)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    deinit { stop() }
}

// MARK: - Microphone

/// The default input device, for "Include my microphone".
/// A microphone (or any sound input) the Mac can record from.
struct InputDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    /// Stays the same across restarts and reconnections, so it is what Settings keep.
    let uid: String
    let name: String

    /// Every device with at least one input channel, in the order Core Audio lists them.
    static func all() -> [InputDevice] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = text(id, kAudioDevicePropertyDeviceUID), let name = text(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var where_ = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &where_, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &where_, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func text(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var where_ = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &where_, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// The inputs of the Mac, kept current by Core Audio when a headset or a phone comes and goes.
/// Read once and on change only: refreshing the list while the pointer moves over the menu rebuilt the
/// view under SwiftUI's hit test and crashed Earshot.
@Observable @MainActor
final class InputDevices {
    static let shared = InputDevices()
    private(set) var list = InputDevice.all()

    private init() {
        var where_ = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &where_, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { InputDevices.shared.list = InputDevice.all() }
        }
    }
}

/// The user's microphone, read through AVCaptureSession: it opens exactly the input chosen in Settings
/// (AVAudioEngine's input node keeps the Mac's default input on macOS, so a Bluetooth headset stayed
/// in call mode with its sound degraded). Samples come out as 16 kHz mono floats.
final class Microphone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "earshot.microphone", qos: .userInitiated)
    private let onSamples: ([Float]) -> Void

    enum Failure: LocalizedError {
        case denied
        case noInput
        var errorDescription: String? {
            switch self {
            case .denied: String(localized: "Earshot cannot use the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
            case .noInput: String(localized: "No microphone found.")
            }
        }
    }

    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    /// How the user appears in transcripts: their macOS account name.
    static var speakerName: String { NSFullUserName().isEmpty ? String(localized: "Me") : NSFullUserName() }

    /// `deviceUID`: the input chosen in Settings (a Core Audio UID, which is also the capture device's
    /// unique ID); "" or a device that is not plugged in: the Mac's default input.
    init(deviceUID: String = "", onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples
        super.init()
        let chosen = deviceUID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceUID)
        guard let device = chosen ?? AVCaptureDevice.default(for: .audio) else { throw Failure.noInput }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw Failure.noInput }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= MemoryLayout<Float>.size else { return }
        var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        onSamples(chunk)
    }

    func stop() {
        session.stopRunning()
    }
}

/// Puts the microphone on the app's clock, for its own track and the saved audio. The microphone is never muted:
/// with speakers it also hears the app, so the app's sound is taken out of it (`LiveEchoCanceller`), and the user's
/// words stay even when they speak over the other side. With headphones there is nothing to take out.
final class MicMix {
    /// The microphone starts 100 ms behind: its buffers come in bigger chunks than the app's, and running dry would
    /// shift it against the app's sound (and the echo with it).
    static let cushion = 1_600
    private let lock = NSLock()
    private var pending = [Float](repeating: 0, count: cushion)
    private let echo = LiveEchoCanceller()
    private var cleaned = [Float](repeating: 0, count: LiveEchoCanceller.latency)

    /// Microphone in, from its own thread.
    func addMic(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        pending += samples
        if pending.count > 16_000 { pending.removeFirst(pending.count - 16_000) }  // keep the two clocks within 1 s
    }

    /// App audio in, from the app's thread: app + cleaned microphone (for the saved file), the microphone as recorded
    /// on the app's clock (for its own track, cleaned again once the call is over), and the cleaned microphone so far
    /// (for the live transcriber).
    func split(_ samples: [Float]) -> (mix: [Float], mic: [Float], cleaned: [Float]) {
        var mic = [Float](repeating: 0, count: samples.count)
        lock.lock()
        let n = min(samples.count, pending.count)
        for i in 0..<n { mic[i] = pending[i] }
        pending.removeFirst(n)
        lock.unlock()
        let clean = echo.process(reference: samples, mic: mic)
        cleaned += clean
        var out = samples
        let m = min(out.count, cleaned.count)
        for i in 0..<m { out[i] += cleaned[i] }
        cleaned.removeFirst(m)
        return (out, mic, clean)
    }
}

/// Sound saved as it comes, as raw 16 kHz 16-bit samples: there is nothing to finalize, so a forced quit, a crash
/// or a Mac that shuts down loses at most the last buffer. Encoded to Audio.m4a once the recording is over.
final class RawTrack {
    let url: URL
    private let handle: FileHandle

    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.url = url
    }

    /// From the audio thread.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let pcm = samples.map { Int16(clamping: Int(($0 * 32_767).rounded())) }
        pcm.withUnsafeBytes { try? handle.write(contentsOf: Data($0)) }
    }

    func close() { try? handle.close() }

    static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 } }
    }
}

/// The live transcriber the audio thread feeds, if any: set and cleared from the main thread when the mode changes.
final class TranscriberSlot {
    private let lock = NSLock()
    private var value: StreamingTranscriber?

    var transcriber: StreamingTranscriber? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    func take() -> StreamingTranscriber? {
        lock.lock(); defer { lock.unlock() }
        let t = value
        value = nil
        return t
    }

    func append(_ samples: [Float]) { transcriber?.append(samples) }
}

/// The level of the captured sound, ten times a second, for the meter (when no live transcriber reports it).
final class LevelFeed {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let report: (Float) -> Void

    init(_ report: @escaping (Float) -> Void) { self.report = report }

    func append(_ samples: [Float]) {
        lock.lock()
        let due = Date().timeIntervalSince(last) > 0.1
        if due { last = Date() }
        lock.unlock()
        guard due else { return }
        report(sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))))
    }
}

// MARK: - Format conversion

/// Converts any PCM buffer to 16 kHz mono float samples, the format Whisper wants (or to `output`).
final class Resampler {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let output: AVAudioFormat
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from input: AVAudioFormat, to output: AVAudioFormat = Resampler.format) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.output = output
        ratio = output.sampleRate / input.sampleRate
    }

    /// 16 kHz samples as a buffer, for AVFoundation APIs.
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return out.frameLength > 0 ? out : nil
    }

    func callAsFunction(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let out = convert(buffer), let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
