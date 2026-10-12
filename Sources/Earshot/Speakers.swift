import AppKit
import ApplicationServices

/// Reads who is speaking from Teams' own live captions, through the accessibility API.
///
/// Teams renders captions in an `AXGroup` described "Live Captions": a run of `AXStaticText` pairs
/// (name, text). Older entries get re-rendered, so only the newest one tells who is speaking now.
/// Captions run about 1.5 s behind the audio.
final class TeamsCaptions {
    static func handles(_ bundleID: String) -> Bool { bundleID.hasPrefix("com.microsoft.teams") }
    static let lag = 1.5

    private let app: AXUIElement
    private var captions: AXUIElement?
    private var previous = Set<String>()
    private var first = true
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "earshot.captions")
    /// (wall-clock time the line appeared, speaker name)
    var onSpeaker: (Date, String) -> Void = { _, _ in }

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        // Electron only builds its accessibility tree when asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.4)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        if captions == nil { captions = find(in: app, depth: 0) { $0.role == "AXGroup" && $0.description == "Live Captions" } }
        guard let captions else { return }
        var texts: [String] = []
        collectTexts(captions, into: &texts, depth: 0)
        if texts.isEmpty { self.captions = nil; return }
        var entries: [String] = []
        var i = 0
        while i + 1 < texts.count { entries.append(texts[i] + "\t" + texts[i + 1]); i += 2 }
        if !first, let last = entries.last, !previous.contains(last) {
            onSpeaker(Date(), Self.displayName(String(last.split(separator: "\t")[0])))
        }
        first = false
        previous = Set(entries)
    }

    /// Turns captions on in the current call if they are off: More › Language and speech › Show live captions.
    func turnOnCaptions() {
        queue.async { [self] in
            if find(in: app, depth: 0, { $0.role == "AXGroup" && $0.description == "Live Captions" }) != nil { return }
            for id in ["callingButtons-showMoreBtn", "LanguageSpeechMenuControl-id", "closed-captions-button"] {
                guard let button = find(in: app, depth: 0, { $0.role != "AXStaticText" && ($0.domID?.contains(id) ?? false) }) else { return }
                AXUIElementPerformAction(button, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 1.2)
            }
        }
    }

    /// Teams shows "LASTNAME Firstname" (plus "-EXTERNAL" for guests): turn it into "Firstname Lastname".
    static func displayName(_ raw: String) -> String {
        let tokens = raw.replacingOccurrences(of: "-EXTERNAL", with: "").replacingOccurrences(of: "-EXTERNE", with: "")
            .split(separator: " ").map(String.init)
        let caps = tokens.filter { $0.count > 1 && $0 == $0.uppercased() && $0 != $0.lowercased() }
        let rest = tokens.filter { !caps.contains($0) }
        return caps.isEmpty || rest.isEmpty ? tokens.joined(separator: " ") : (rest + caps.map(\.capitalized)).joined(separator: " ")
    }

    // MARK: AX tree walking

    private struct Node { let role: String?; let description: String?; let domID: String? }

    private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    private func find(in e: AXUIElement, depth: Int, _ match: (Node) -> Bool) -> AXUIElement? {
        if depth > 80 { return nil }
        let node = Node(role: attribute(e, kAXRoleAttribute) as? String,
                        description: attribute(e, kAXDescriptionAttribute) as? String,
                        domID: attribute(e, "AXDOMIdentifier") as? String)
        if match(node) { return e }
        for child in children(e) { if let hit = find(in: child, depth: depth + 1, match) { return hit } }
        return nil
    }

    private func collectTexts(_ e: AXUIElement, into out: inout [String], depth: Int) {
        if depth > 30 { return }
        if attribute(e, kAXRoleAttribute) as? String == "AXStaticText" {
            let s = attribute(e, kAXValueAttribute) as? String ?? attribute(e, kAXDescriptionAttribute) as? String ?? ""
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { out.append(s) }
        }
        for child in children(e) { collectTexts(child, into: &out, depth: depth + 1) }
    }
}

/// Who spoke when, from the captions, in session time.
struct SpeakerTimeline {
    private(set) var marks: [(time: Double, name: String)] = []

    mutating func add(_ time: Double, _ name: String) { marks.append((time - TeamsCaptions.lag, name)) }

    var latest: String? { marks.last?.name }

    /// The name heard most over [start, end], else the last one heard within 8 s before.
    func speaker(from start: Double, to end: Double) -> String? {
        var counts: [String: Int] = [:]
        for m in marks where m.time >= start - 0.5 && m.time <= end + 1 { counts[m.name, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value })?.key { return best }
        if let before = marks.last(where: { $0.time < start }), start - before.time < 8 { return before.name }
        return nil
    }
}
