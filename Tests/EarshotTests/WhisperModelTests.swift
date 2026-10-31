import Foundation
import Testing
@testable import Earshot

@Suite struct WhisperModelTests {
    func models(_ names: [String]) -> [WhisperModel] { names.map { WhisperModel(url: URL(filePath: "/models/ggml-\($0).bin")) } }

    @Test func installedModelsAreGgmlBinFilesFromEachFolderWithTheFirstFolderWinning() throws {
        try withTempFolder { root in
            let own = root.appending(path: "own"), cache = root.appending(path: "cache"), missing = root.appending(path: "missing")
            for (folder, files) in [(own, ["ggml-small.bin", "ggml-base.bin", "ggml-base.bin.part", "base.bin", "notes.txt"]),
                                    (cache, ["ggml-base.bin", "ggml-large-v3.bin"])] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in files { try Data().write(to: folder.appending(path: file)) }
            }
            let found = WhisperModel.installed(in: [own, missing, cache])
            #expect(found.map(\.name) == ["base", "small", "large-v3"])
            #expect(found.first?.url.deletingLastPathComponent().lastPathComponent == "own")
        }
    }

    @Test func theModelNameDropsThePrefixAndTheExtension() {
        #expect(models(["large-v3-turbo"]).first?.name == "large-v3-turbo")
        #expect(models(["base.en"]).first?.name == "base.en")
    }

    @Test func preferredModelIsTheChosenOneThenTurboThenLargeThenTheFirst() {
        let all = models(["base", "large-v3", "large-v3-turbo", "small"])
        #expect(WhisperModel.preferred("/models/ggml-small.bin", from: all)?.name == "small")
        #expect(WhisperModel.preferred("", from: all)?.name == "large-v3-turbo")
        #expect(WhisperModel.preferred("/models/ggml-deleted.bin", from: all)?.name == "large-v3-turbo")
        #expect(WhisperModel.preferred("", from: all.filter { $0.name != "large-v3-turbo" })?.name == "large-v3")
        #expect(WhisperModel.preferred("", from: models(["small", "base"]))?.name == "small")
        #expect(WhisperModel.preferred("", from: []) == nil)
    }
}
