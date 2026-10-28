#if DEBUG
import AppKit

/// With `NN_SELFTEST_EQ=1` (no internet: a tone made here, played from the audio cache): Settings › Playback ›
/// Equalizer (#37). The filters on tones, offline; presets and what is stored; then the player: no tap while off, the tap
/// at once when switched on mid-song, the song's audio cut by a band as the band says, and the tap gone when switched
/// off. Muted; the settings it changes are put back.
extension SelfTest {
    private static var startedEqualizer = false

    static func runEqualizerCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_EQ"] != nil, !startedEqualizer else { return }
        startedEqualizer = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("eq \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            func near(_ value: Double, _ target: Double, _ within: Double) -> Bool { abs(value - target) <= within }
            func db(_ value: Double?) -> String { value.map { String(format: "%+.2f dB", $0) } ?? "no audio" }
            let eq = Equalizer.shared
            try? await Task.sleep(for: .seconds(2))
            borrowDefaults(["eqOn", "eqGains", "eqPreset", "audioCacheMB", "autoplay"])
            @MainActor func finish() {
                eq.setOn(false)
                returnDefaults()
                report("eq: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }

            // A. the filters, on tones, offline (as the tap runs them)
            var gains = Array(repeating: 0.0, count: 14)
            let flat = SoundProcessor(gains: gains).offline(frequency: 500)
            check("flat leaves the audio as it is", near(flat, 0, 0.05), db(flat))
            gains[6] = -12
            let cut = SoundProcessor(gains: gains), cutAt500 = cut.offline(frequency: 500), cutAt2k = cut.offline(frequency: 2000)
            check("−12 dB at 500 Hz takes 12 dB off a 500 Hz tone and almost nothing off 2 kHz",
                  near(cutAt500, -12, 0.5) && near(cutAt2k, 0, 1), "\(db(cutAt500)), \(db(cutAt2k))")
            gains[6] = 12
            let boost = SoundProcessor(gains: gains), boostAt500 = boost.offline(frequency: 500), boostAt2k = boost.offline(frequency: 2000)
            check("+12 dB at 500 Hz: the preamp keeps 500 Hz where it was and turns the rest down, so nothing clips",
                  near(boostAt500, 0, 0.5) && boostAt2k < -10, "\(db(boostAt500)), \(db(boostAt2k))")

            // B. presets and what is stored
            eq.choose(.bassBoost)
            check("a preset sets its curve and is stored", eq.gains == Equalizer.Preset.bassBoost.gains
                  && UserDefaults.standard.array(forKey: "eqGains") as? [Double] == eq.gains
                  && UserDefaults.standard.string(forKey: "eqPreset") == "bassBoost")
            eq.set(band: 13, to: 3.3)
            check("moving a band makes the curve Custom, in 0.5 dB steps", eq.preset == .custom && eq.gains[13] == 3.5,
                  "\(eq.preset.rawValue), \(eq.gains[13])")
            eq.set(band: 0, to: 40)
            check("a band stops at +12 dB", eq.gains[0] == 12)
            eq.choose(.flat)

            // C. the player: a 500 Hz tone from the cache
            UserDefaults.standard.set(500, forKey: "audioCacheMB")
            UserDefaults.standard.set(false, forKey: "autoplay")
            guard let file = tone(hz: 500, seconds: 40) else { check("a tone made with afconvert", false); finish(); return }
            let listing = Listing(source: "jiosaavn", id: "selftest-eq-\(UUID().uuidString)", title: "Equalizer", artists: ["Self-Test"],
                                  album: nil, duration: 40, popularity: nil, image: nil)
            try? FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
            try? file.write(to: AudioCache.shared.path(for: listing.key))
            defer { Task { await AudioCache.shared.remove(listing.key) } }
            if !player.isMuted { player.toggleMute() }
            eq.setOn(false)
            player.play([Track(best: listing, listings: [listing], choosingVersion: false)])
            check("(the tone plays)", await until(10) { player.isPlaying && player.livePosition > 1 })
            check("off: the song has no tap at all", !player.itemHasTapForTests)

            eq.setOn(true)
            var frames = 0
            let tapped = await until(5) {
                frames = SoundChain.shared.liveProcessors.map { $0.takeReading().frames }.max() ?? 0
                return player.itemHasTapForTests && frames > 0
            }
            check("switched on mid-song, the song's audio goes through the tap at once", tapped,
                  "tap \(player.itemHasTapForTests), \(frames) frames\(player.isMuted ? ", muted" : "")")
            @MainActor func heard() async -> Double? {
                _ = SoundChain.shared.liveProcessors.map { $0.takeReading() }                 // from now
                try? await Task.sleep(for: .seconds(1.5))
                return SoundChain.shared.liveProcessors.compactMap { $0.takeReading().change }.first
            }
            let flatLive = await heard()
            check("flat, the song's audio is as it was", flatLive.map { near($0, 0, 0.3) } ?? false, db(flatLive))
            eq.set(band: 6, to: -12)
            let cutLive = await heard()
            check("−12 dB at 500 Hz cuts the playing 500 Hz tone by about 12 dB", cutLive.map { near($0, -12, 1.5) } ?? false, db(cutLive))
            eq.choose(.flat)

            eq.setOn(false)
            check("switched off, the song's tap is taken away", await until(3) { !player.itemHasTapForTests })
            if player.isPlaying { player.togglePlayPause() }
            finish()
        }
    }

    /// A stereo sine of `hz` as AAC in MP4, made with afconvert as the loader's test makes its file. `peak`: its
    /// amplitude in 16-bit steps (8000 is −12.3 dBFS).
    static func tone(hz: Double, seconds: Int, peak: Double = 8000) -> Data? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nn-eq-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 44100
        var wav = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        let bytes = rate * seconds * 4
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(bytes)
        var samples = [Int16](repeating: 0, count: rate * seconds * 2)
        for i in 0..<(rate * seconds) {
            let v = Int16(peak * sin(Double(i) * 2 * .pi * hz / Double(rate)))
            samples[2 * i] = v; samples[2 * i + 1] = v
        }
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        try? wav.write(to: dir.appending(path: "tone.wav"))
        let convert = Process()
        convert.executableURL = URL(filePath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "192000", dir.appending(path: "tone.wav").path, dir.appending(path: "tone.m4a").path]
        try? convert.run()
        convert.waitUntilExit()
        return try? Data(contentsOf: dir.appending(path: "tone.m4a"))
    }
}
#endif
