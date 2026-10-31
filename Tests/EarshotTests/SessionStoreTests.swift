import Foundation
import Testing
@testable import Earshot

/// Sessions on disk: what recording writes and the Library reads back.
@Suite struct SessionStoreTests {
    /// Saves `record` the way a recording does, in <base>/<group>/<day>.
    @discardableResult
    func save(_ record: SessionRecord, in base: URL, group: String = "Stratégie digitale", day: String = "2026-09-21") throws -> URL {
        let folder = base.appending(path: group).appending(path: day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SessionStore.write(record, to: folder)
        return folder
    }

    @Test func aSavedSessionLoadsBackWithItsTranscriptFile() throws {
        try withTempFolder { base in
            let record = sampleRecord()
            let folder = try save(record, in: base)
            let loaded = SessionStore.loadAll(base: base)
            #expect(loaded.count == 1)
            var expected = record
            expected.folder = loaded.first?.folder
            #expect(loaded.first == expected)
            #expect(loaded.first?.folder?.lastPathComponent == "2026-09-21")
            #expect(loaded.first?.group == "Stratégie digitale")
            #expect(try String(contentsOf: folder.appending(path: "Transcript.txt"), encoding: .utf8) == SessionStore.text(record))
        }
    }

    /// Sessions recorded by older versions must keep opening: this is the JSON as saved, field names included.
    @Test func theJSONOnDiskKeepsItsShape() throws {
        let json = """
            {
              "appName" : "Teams",
              "bundleID" : "com.microsoft.teams2",
              "duration" : 90.5,
              "id" : "0E9A5C0B-5E55-4B8B-8C6E-0C4F6B5E1A11",
              "segments" : [
                { "end" : 4.2, "id" : "1B1F0F5C-4A3B-4C55-9A67-2D0B2F7E9A01", "speaker" : "Jane Doe", "start" : 0, "text" : "Bonjour." },
                { "end" : 9, "id" : "1B1F0F5C-4A3B-4C55-9A67-2D0B2F7E9A02", "mic" : true, "speaker" : "Moi", "start" : 5, "text" : "Hello." },
                { "end" : 12, "id" : "1B1F0F5C-4A3B-4C55-9A67-2D0B2F7E9A03", "start" : 10, "text" : "Sans nom." }
              ],
              "startedAt" : "2026-09-21T08:00:00Z",
              "title" : "Réunion"
            }
            """
        try withTempFolder { base in
            let folder = base.appending(path: "Réunion/2026-09-21")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: folder.appending(path: SessionStore.recordName), atomically: true, encoding: .utf8)
            let record = try #require(SessionStore.loadAll(base: base).first)
            #expect(record.title == "Réunion" && record.appName == "Teams" && record.bundleID == "com.microsoft.teams2" && record.duration == 90.5)
            #expect(record.startedAt == Date(timeIntervalSince1970: 1_789_977_600))
            #expect(record.segments.map(\.speaker) == ["Jane Doe", "Moi", nil])
            #expect(record.segments.map(\.mic) == [nil, true, nil])
            #expect(record.segments.map(\.end) == [4.2, 9, 12])
        }
    }

    @Test func theLibraryIsNewestFirstAndSkipsUnreadableRecords() throws {
        try withTempFolder { base in
            var older = sampleRecord(), newer = sampleRecord()
            older.title = "Older"
            newer.title = "Newer"
            newer.startedAt = sessionStart.addingTimeInterval(86_400)
            try save(older, in: base, day: "2026-09-21")
            try save(newer, in: base, group: "Other", day: "2026-09-22")
            for (name, content) in [("Cut short", "{\"title\" : \"Cut"), ("Missing fields", "{\"title\" : \"No segments\"}")] {
                let folder = base.appending(path: name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try content.write(to: folder.appending(path: SessionStore.recordName), atomically: true, encoding: .utf8)
            }
            #expect(SessionStore.loadAll(base: base).map(\.title) == ["Newer", "Older"])
        }
        #expect(SessionStore.loadAll(base: URL(filePath: "/nonexistent/earshot-tests")).isEmpty)
    }

    @Test func sessionsOfTheSameDayGetNumberedFolders() throws {
        try withTempFolder { base in
            let first = SessionStore.newFolder(base: base, group: "Marketing / Stratégie")
            #expect(first.deletingLastPathComponent().lastPathComponent == "Marketing - Stratégie")
            let day = first.lastPathComponent
            #expect(day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            let second = SessionStore.newFolder(base: base, group: "Marketing / Stratégie")
            #expect(second.lastPathComponent == "\(day) 2")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            #expect(SessionStore.newFolder(base: base, group: "Marketing / Stratégie").lastPathComponent == "\(day) 3")
        }
    }
}
