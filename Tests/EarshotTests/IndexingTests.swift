import Foundation
import Testing
@testable import Earshot

/// Running doc-indexer after a transcript: finding its script, and reading how a run went.
@Suite struct IndexingTests {
    let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theSummaryLineGivesTheNumberOfFiles() {
        let output = """
        up to date        412  Recordings/Marketing/2026-11-10/Transcript.txt
        extracted         388  Recordings/Marketing/2026-11-11/Transcript.txt
        skipped             0  Recordings/Marketing/2026-11-11/Audio.m4a

        12 files: 10 up to date, 1 extracted, 1 skipped
        Text and manifest in /Users/someone/Documents/School/.doc-index
        """
        #expect(DocIndexer.outcome(status: 0, output: output, at: date) == .done(date, files: 12))
    }

    @Test func aFileNamedLikeTheSummaryIsNotTakenForIt() {
        let output = "extracted          5  3 files: notes.txt\n\n1 files: 1 extracted\n"
        #expect(DocIndexer.outcome(status: 0, output: output, at: date) == .done(date, files: 1))
        #expect(DocIndexer.outcome(status: 0, output: "0 files: nothing to index\n", at: date) == .done(date, files: 0))
    }

    @Test func aFailedRunShowsItsLastLine() {
        let output = "usage: extract_texts.py [-h] source\nextract_texts.py: error: not a folder: /nowhere\n"
        #expect(DocIndexer.outcome(status: 2, output: output) == .failed("extract_texts.py: error: not a folder: /nowhere"))
        #expect(DocIndexer.outcome(status: 1, output: "") != .done(date, files: 0))
    }

    @Test func theScriptIsFoundFromItsFolderOrItself() throws {
        try withTempFolder { base in
            let repo = base.appending(path: "Developer/doc-indexer-macos")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let script = repo.appending(path: "extract_texts.py")
            try "print('0 files: nothing to index')\n".write(to: script, atomically: true, encoding: .utf8)
            try "".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)

            #expect(DocIndexer.script(from: repo)?.path == script.path)
            #expect(DocIndexer.script(from: script)?.path == script.path)
            #expect(DocIndexer.script(from: repo.appending(path: "README.md")) == nil)
            #expect(DocIndexer.script(from: base) == nil)
            #expect(DocIndexer.found(home: base)?.path == script.path)
            #expect(DocIndexer.found(home: base.appending(path: "Elsewhere")) == nil)
        }
    }

    @Test func aRunPassesTheFolderAndReadsTheSummary() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "earshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appending(path: "extract_texts.py")
        // Stands in for doc-indexer: one line per file, enough to fill a pipe, then the summary for the folder it got.
        try """
        import os, sys
        for i in range(3000): print(f"up to date        12  Recordings/Session {i}/Transcript.txt")
        print(f"\\n{len(os.listdir(sys.argv[1]))} files: all up to date")
        """.write(to: script, atomically: true, encoding: .utf8)
        let folder = base.appending(path: "School")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] { try "x".write(to: folder.appending(path: name), atomically: true, encoding: .utf8) }

        guard case let .done(_, files) = await DocIndexer.run(script: script, folder: folder) else { Issue.record("the run failed"); return }
        #expect(files == 2)
        guard case .failed = await DocIndexer.run(script: script, folder: base.appending(path: "Missing")) else { Issue.record("a missing folder was indexed"); return }
    }
}
