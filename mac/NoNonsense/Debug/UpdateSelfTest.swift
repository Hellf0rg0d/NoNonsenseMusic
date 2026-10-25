#if DEBUG
import AppKit

/// With `NN_SELFTEST_UPDATE=1` and `NN_UPDATE_FEED=<appcast>` (mac.yml, a local server): Sparkle checks that feed,
/// downloads the update, checks its EdDSA signature against the test key (mac/UpdateTest), and installs it at once,
/// opening the new version. What it did is reported; the CI step then reads the app on disk, which must be the new
/// version, or (for a tampered update) still the old one.
extension SelfTest {
    private static var startedUpdate = false

    /// The update self-test's appcast, for Updater.
    static var updateFeed: String? {
        let env = ProcessInfo.processInfo.environment
        return env["NN_SELFTEST_UPDATE"] != nil ? env["NN_UPDATE_FEED"] : nil
    }

    static func updateEvent(_ event: String) {
        report("update: \(event)")
        if event.hasPrefix("aborted") { NSApp.terminate(nil) }
    }

    static func runUpdateCheckIfAsked() {
        guard updateFeed != nil, !startedUpdate else { return }
        startedUpdate = true
        Task { @MainActor in
            report("update: this app is \(Updater.current) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            for _ in 0..<100 where !Updater.shared.canCheck { try? await Task.sleep(for: .milliseconds(100)) }
            guard Updater.shared.canCheck else { report("update: Sparkle did not start"); NSApp.terminate(nil); return }
            Updater.shared.checkInBackgroundForTests()
            try? await Task.sleep(for: .seconds(60))                // the update, or its refusal, comes well before
            report("update: nothing happened in 60 s")
            NSApp.terminate(nil)
        }
    }
}
#endif
