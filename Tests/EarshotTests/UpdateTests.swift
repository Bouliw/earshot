import Foundation
import Testing
@testable import Earshot

/// The daily check against GitHub's latest release: only a newer version is shown.
@Suite struct UpdateTests {
    @Test func versionsAreComparedNumberByNumber() {
        #expect(UpdateCheck.isNewer("0.6.4", than: "0.6.3"))
        #expect(UpdateCheck.isNewer("0.6.10", than: "0.6.9"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateCheck.isNewer("0.6.3", than: "0.6.3"))
        #expect(!UpdateCheck.isNewer("0.7", than: "0.7.0"))
        #expect(!UpdateCheck.isNewer("0.6.2", than: "0.6.3"))
    }

    @Test func theVersionIsTheReleaseTagWithoutItsV() {
        #expect(UpdateCheck.version(fromRelease: Data(#"{"tag_name": "v0.7.0", "draft": false}"#.utf8)) == "0.7.0")
        #expect(UpdateCheck.version(fromRelease: Data(#"{"tag_name": "0.7.1"}"#.utf8)) == "0.7.1")
        #expect(UpdateCheck.version(fromRelease: Data(#"{"message": "Not Found"}"#.utf8)) == nil)
        #expect(UpdateCheck.version(fromRelease: Data(#"{"tag_name": "nightly"}"#.utf8)) == nil)
    }
}
