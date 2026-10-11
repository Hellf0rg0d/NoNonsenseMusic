#if DEBUG
import AppKit

/// With `NN_SELFTEST_SEARCHSCROLL=1` (needs the internet): nothing under Search's artist row scrolls but the results
/// list, so a scroll that starts there moves the results.
extension SelfTest {
    private static var startedSearchScroll = false

    static func runSearchScrollCheckIfAsked() {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_SEARCHSCROLL"] != nil, !startedSearchScroll else { return }
        startedSearchScroll = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("searchscroll \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            try? await Task.sleep(for: .seconds(3))
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .selfTestSearch, object: "arijit singh")
            for _ in 0..<150 where frames["search.artists"] == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1.5))
            guard let shelf = frames["search.artists"],
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }), let content = window.contentView else {
                check("Search shows the artists row", false); NSApp.terminate(nil); return
            }
            let inWindow = NSPoint(x: shelf.midX, y: content.bounds.height - shelf.midY)
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            let scrolls = views(content).compactMap { $0 as? NSScrollView }.filter { $0.convert($0.bounds, to: nil).contains(inWindow) }
            guard let page = scrolls.max(by: { $0.frame.height < $1.frame.height }) else {
                check("the results' scroll view", false); NSApp.terminate(nil); return
            }
            // the bug was a sideways scroll view under the pointer, inside the results' own: it took every scroll that
            // started over it. Synthetic scroll events do not move SwiftUI's list from inside the app (a control scroll
            // over the songs moved it 0 pt too), so the structure is what is checked: one scroll view there, the list's
            check("under the artists row, the results list is the only scroll view", scrolls.count == 1 && scrolls.first === page,
                  scrolls.map { "\(type(of: $0))" }.joined(separator: ", "))
            report("searchscroll: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
