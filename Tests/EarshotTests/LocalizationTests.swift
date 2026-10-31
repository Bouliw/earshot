import Foundation
import Testing

/// The French tables are read from Resources: `swift test` cannot load them as the app does,
/// `Earshot --check` covers the keys with interpolations in the built app.
@Suite struct LocalizationTests {
    let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")

    func table(_ path: String) throws -> [String: String] {
        try #require(NSDictionary(contentsOf: resources.appending(path: path), error: ()) as? [String: String])  // throws on a syntax error
    }

    func placeholders(_ text: String) throws -> [String] {
        let format = try Regex(#"%(\d+\$)?(lld|ld|d|@|f|s)"#)
        return text.matches(of: format).map { String(text[$0.range]) }.sorted()
    }

    @Test func theFrenchTableHasNoDuplicateEmptyOrMismatchedEntries() throws {
        let table = try table("fr.lproj/Localizable.strings")
        let source = try String(contentsOf: resources.appending(path: "fr.lproj/Localizable.strings"), encoding: .utf8)
        #expect(source.split(separator: "\n").filter { $0.hasPrefix("\"") }.count == table.count, "a key appears twice")
        for (key, value) in table {
            #expect(!value.isEmpty, "empty translation of \(key)")
            #expect(try placeholders(key) == placeholders(value), "placeholders differ in \(key)")
        }
    }

    @Test func frenchPermissionPromptsMatchTheKeysInInfoPlist() throws {
        let info = try #require(NSDictionary(contentsOf: resources.appending(path: "Info.plist"), error: ()) as? [String: Any])
        let prompts = Set(info.keys.filter { $0.hasSuffix("UsageDescription") })
        let french = Set(try table("fr.lproj/InfoPlist.strings").keys)
        #expect(french.isSubset(of: prompts), "a French prompt for a key Info.plist does not have: \(french.subtracting(prompts))")
        // NSSpeechRecognitionUsageDescription has no French text yet.
        withKnownIssue("not every permission prompt is translated") { #expect(prompts.subtracting(french).isEmpty) }
    }
}
