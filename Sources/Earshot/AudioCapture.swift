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
    private var converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case let .coreAudio(step, status): "Could not capture audio (\(step), error \(status)). Check System Settings › Privacy & Security › Screen & System Audio Recording."
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
        inputFormat = AVAudioFormat(streamDescription: &asbd) ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat)

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

        let format = inputFormat
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            if let samples = self.convert(buffer) { onSamples(samples) }
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

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter, buffer.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
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
