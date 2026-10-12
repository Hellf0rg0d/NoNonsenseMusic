import Foundation
import Observation

/// "An update is available": once per launch the app asks GitHub for the latest release and compares its tag with its
/// own version. The one request the app makes that does not go to your server; Settings › Account › Check for Updates
/// turns it off. GitHub answers only for a public repository: while it is private the check finds nothing and says
/// nothing.
@MainActor @Observable
final class UpdateCheck {
    static let shared = UpdateCheck()
    static let latestURL = URL(string: "https://api.github.com/repos/ego004/NoNonsenseMusic/releases/latest")!

    struct Release: Equatable {
        let version: String      // "0.3.0"
        let page: URL            // the release's page, where the downloads are
    }

    /// A newer release than this app, not skipped: the alert shows while this is set.
    var available: Release?

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates") }
    }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func check() async {
        guard Self.enabled, available == nil else { return }
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: Self.current),
              version != UserDefaults.standard.string(forKey: "skippedUpdate") else { return }
        available = Release(version: version, page: page)
    }

    /// Not asked about this one again; a later release is.
    func skip() {
        if let available { UserDefaults.standard.set(available.version, forKey: "skippedUpdate") }
        available = nil
    }

    /// "0.10.0" is newer than "0.9.1": compared number by number, a missing number counting as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
