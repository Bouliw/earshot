import Foundation

/// Runs doc-indexer on a folder after each transcript, so sessions can be searched with the user's documents.
/// It waits until no call is recorded and no transcript is being written, then runs at background priority
/// (efficiency cores, throttled disk): indexing never warms the Mac up or slows a call down.
@Observable @MainActor
final class DocIndexer {
    enum State: Equatable {
        case idle
        /// Waiting for a recording or a transcript to end.
        case waiting
        case running
        case done(Date, files: Int)
        case failed(String)
    }

    static let shared = DocIndexer()

    private(set) var state = State.idle
    /// Whether to wait: while a call is recorded or a transcript written, nothing else runs.
    var hold: () -> Bool = { false }
    private var pending = false
    private var delay = DocIndexer.settle
    private var worker: Task<Void, Never>?
    /// Changes come in bursts (the transcript, then the voices, then a rename): one run covers them all.
    private static let settle = Duration.seconds(10)

    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: Pref.indexTranscripts) }

    /// The folder doc-indexer reads: the one chosen in Settings, else the one sessions are saved to.
    nonisolated static var folder: URL {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Pref.indexFolder), !path.isEmpty { return URL(filePath: path) }
        return URL(filePath: defaults.string(forKey: Pref.folder) ?? Pref.defaultFolder)
    }

    /// doc-indexer's extract_texts.py: the one chosen in Settings, else the first found where code usually lives.
    nonisolated static var script: URL? {
        if let path = UserDefaults.standard.string(forKey: Pref.indexer), !path.isEmpty {
            return FileManager.default.fileExists(atPath: path) ? URL(filePath: path) : nil
        }
        return found()
    }

    nonisolated static func found(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        for parent in ["", "Developer", "Projects", "Code", "src", "GitHub", "Documents/GitHub", "Documents", "Desktop"] {
            for name in ["doc-indexer-macos", "doc-indexer"] {
                let path = [home.path, parent, name, "extract_texts.py"].filter { !$0.isEmpty }.joined(separator: "/")
                if FileManager.default.fileExists(atPath: path) { return URL(filePath: path) }
            }
        }
        return nil
    }

    /// A file or a folder picked in Settings, as the script to run (a doc-indexer folder holds it).
    nonisolated static func script(from url: URL) -> URL? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        let file = isFolder.boolValue ? url.appending(path: "extract_texts.py") : url
        return file.lastPathComponent == "extract_texts.py" && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Indexes once things are quiet: a few seconds after the last change, with no call or transcript running.
    func schedule() {
        guard Self.isOn else { return }
        pending = true
        if worker == nil { worker = Task { await drain() } }
    }

    /// "Index now" in Settings: no settling time (a call or a transcript in progress still comes first).
    func indexNow() {
        delay = .zero
        schedule()
    }

    private func drain() async {
        while pending {
            try? await Task.sleep(for: delay)
            delay = Self.settle
            while hold() {
                state = .waiting
                try? await Task.sleep(for: .seconds(5))
            }
            pending = false
            guard Self.isOn else { state = .idle; break }
            guard let script = Self.script else {
                state = .failed(String(localized: "doc-indexer was not found. Choose its extract_texts.py above."))
                break
            }
            state = .running
            state = await Self.run(script: script, folder: Self.folder)
        }
        worker = nil
    }

    /// One doc-indexer run, off the main thread and at background priority.
    nonisolated static func run(script: URL, folder: URL) async -> State {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                continuation.resume(returning: Self.runNow(script: script, folder: folder))
            }
        }
    }

    nonisolated private static func runNow(script: URL, folder: URL) -> State {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .failed(String(localized: "The folder to index does not exist yet."))
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-I", script.path, folder.path]
        process.qualityOfService = .background  // efficiency cores and throttled disk: the Mac stays cool
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        // Read until the end before waiting, or a long list of files would fill the pipe and block the run.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return outcome(status: process.terminationStatus, output: output)
    }

    /// doc-indexer's summary ("12 files: 10 up to date, 2 extracted"), or the last line it wrote when it failed.
    nonisolated static func outcome(status: Int32, output: String, at date: Date = Date()) -> State {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard status == 0 else {
            return .failed(lines.last ?? String(localized: "doc-indexer stopped (code \(Int(status)))."))
        }
        let files = lines.compactMap { line -> Int? in
            guard let r = line.range(of: " files: ") else { return nil }
            return Int(line[..<r.lowerBound])
        }.last ?? 0
        return .done(date, files: files)
    }
}
