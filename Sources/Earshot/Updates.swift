import Foundation

/// Once a day, asks GitHub for the number of the latest Earshot release, and keeps it when it is newer than this
/// copy. Nothing else is sent: no audio, no transcript, no identifier. Off when "Check for new versions" is unticked.
@Observable @MainActor
final class UpdateCheck {
    static let releasesPage = URL(string: "https://github.com/Bouliw/earshot/releases/latest")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/Bouliw/earshot/releases/latest")!

    /// The newer version on GitHub ("0.7.0"), nil when this copy is the latest or nothing could be checked.
    private(set) var available: String?

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var isOn: Bool { UserDefaults.standard.object(forKey: Pref.checkUpdates) as? Bool ?? true }

    /// At launch, then every 24 hours for as long as Earshot runs.
    func run() async {
        while !Task.isCancelled {
            if Self.isOn { await check() }
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
        }
    }

    func check() async {
        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Offline, rate limited or an unexpected answer: try again tomorrow, without a word.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = Self.version(fromRelease: data) else { return }
        available = Self.isNewer(latest, than: Self.current) ? latest : nil
    }

    /// Unticked in Settings: the notice goes away.
    func clear() { available = nil }

    /// The version in a GitHub release's JSON: its tag without the leading "v".
    nonisolated static func version(fromRelease data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return version.first?.isNumber == true ? version : nil
    }

    /// Compares dotted versions number by number: 0.6.10 is newer than 0.6.9, and 0.7 the same as 0.7.0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
