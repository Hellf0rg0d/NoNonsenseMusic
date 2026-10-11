#if DEBUG
import AppKit
import Translation

/// With `NN_SELFTEST_TRANSLATE=1` (needs the internet): a Spanish song's lyrics offer Translate; on, the panel shows
/// each line's translation, made on this Mac. Reports whether the language pack was already installed: without it,
/// macOS asks to download it, which a test cannot answer.
extension SelfTest {
    private static var startedTranslate = false

    static func runTranslateCheckIfAsked(player: Player, lyrics: LyricsStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_TRANSLATE"] != nil, !startedTranslate else { return }
        startedTranslate = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("translate \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            if !player.isMuted { player.toggleMute() }
            let pack = await LanguageAvailability().status(from: Locale.Language(identifier: "es"), to: Locale.current.language)
            report("translate: Spanish → \(Locale.current.language.languageCode?.identifier ?? "?") pack: \(pack == .installed ? "installed" : pack == .supported ? "supported, not downloaded" : "unsupported")")
            let saved = UserDefaults.standard.object(forKey: "lyricsTranslated")
            UserDefaults.standard.set(false, forKey: "lyricsTranslated")
            UserDefaults.standard.set("lyrics", forKey: "nowPlayingPanel")
            let query = ProcessInfo.processInfo.environment["NN_TRANSLATE_QUERY"] ?? "despacito luis fonsi"
            guard let song = (try? await API.search(query))?.songs.first.map(Track.init) else {
                check("a Spanish song", false); NSApp.terminate(nil); return
            }
            player.play([song])
            player.showNowPlaying = true
            if ProcessInfo.processInfo.environment["NN_LYRICS_LAYOUT"] != nil {
                try? await Task.sleep(for: .seconds(8))
                func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
                let all = NSApp.windows.compactMap(\.contentView).flatMap(views)
                if let lines = all.first(where: { $0 is LyricLinesView }), let layer = lines.layer {
                    report("lyrics layout: view \(lines.bounds.size), in window \(lines.convert(lines.bounds, to: nil).integral), panel \(frames["lyrics.panel"]?.integral ?? .zero)")
                    let scale: CGFloat = 2
                    let size = lines.bounds.size
                    if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: scale, y: scale)
                        layer.render(in: ctx)
                        if let image = ctx.makeImage() {
                            let url = URL(filePath: (ProcessInfo.processInfo.environment["NN_SELFTEST_SNAP"] ?? NSTemporaryDirectory()) + "/lyrics-layers.png")
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                            report("lyrics layout: wrote \(url.path)")
                        }
                    }
                }
                NSApp.terminate(nil); return
            }
            check("Spanish lyrics offer Translate", await until(20) { frames["lyrics.translate"] != nil })
            if case .found(let found)? = lyrics.state(for: song) {
                check("a line carrying the uploader's translation shows the original only", !found.lines.contains { $0.text.contains("^") })
                if query.contains("despacito") { check("…and the lyrics read as Spanish", LyricsTranslations.foreignLanguage(of: found.lines)?.languageCode?.identifier == "es",
                      LyricsTranslations.foreignLanguage(of: found.lines)?.minimalIdentifier ?? "none") }
            }
            UserDefaults.standard.set(true, forKey: "lyricsTranslated")
            if pack == .installed {
                check("…and show each line's translation", await until(20) {
                    frames["lyrics.translation"] != nil
                }, LyricsTranslations.shared.failed.isEmpty ? "still translating" : "failed")
                let first = LyricsTranslations.shared.lines[song.id]?.first { !$0.isEmpty } ?? "-"
                report("translate: first translated line: \(first)")
            }
            UserDefaults.standard.set(saved, forKey: "lyricsTranslated")
            report("translate: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
