#if DEBUG
import AppKit

/// With `NN_SELFTEST_LEVEL=1` (no internet: tones made here, played from the audio cache): Settings › Playback › Same
/// volume for every song. The gain rules; the processor's gain and its glide, offline; the meter on two AAC tones 23.5 dB
/// apart; then the player: no tap while off, the playing song measured when switched on and brought to −14 LUFS, a song
/// stored in the cache measured before it plays and started at its level, and the tap gone when switched off. Muted;
/// the settings it changes are put back.
extension SelfTest {
    private static var startedLevelling = false

    static func runLevellingCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_LEVEL"] != nil, !startedLevelling else { return }
        startedLevelling = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("level \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            func near(_ value: Double, _ target: Double, _ within: Double) -> Bool { abs(value - target) <= within }
            func db(_ value: Double?) -> String { value.map { String(format: "%+.2f dB", $0) } ?? "no audio" }
            let leveller = Leveller.shared, chain = SoundChain.shared
            try? await Task.sleep(for: .seconds(2))
            borrowDefaults(["levelOn", "eqOn", "audioCacheMB", "autoplay"])
            var keys: [String] = []
            @MainActor func finish() {
                leveller.setOn(false)
                for key in keys {
                    leveller.setForTests(nil, for: key)
                    Task { await AudioCache.shared.remove(key) }
                }
                returnDefaults()
                report("level: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            Equalizer.shared.setOn(false)

            // A. the gain rules
            typealias Reading = LoudnessMeter.Reading
            check("a loud song (−8 LUFS) is turned down 6 dB", near(Leveller.gain(Reading(lufs: -8, peak: -0.1)), -6, 1e-9))
            check("a quiet song with room (−20 LUFS, loudest sample −10 dBFS) is turned up 6 dB",
                  near(Leveller.gain(Reading(lufs: -20, peak: -10)), 6, 1e-9))
            check("a boost stops 1 dB under the loudest sample (−20 LUFS, −3 dBFS: +2 dB, not +6)",
                  near(Leveller.gain(Reading(lufs: -20, peak: -3)), 2, 1e-9))
            check("a boost is at most 12 dB", Leveller.gain(Reading(lufs: -50, peak: -40)) == 12)

            // B. the processor, offline
            let flat = Array(repeating: 0.0, count: Equalizer.bands.count)
            let cut = SoundProcessor(gains: flat, level: -6).offline(frequency: 1000)
            check("a −6 dB level takes 6 dB off", near(cut, -6, 0.05), db(cut))
            let gliding = SoundProcessor(gains: flat, level: -6)
            let glide = gliding.offline(frequency: 1000, seconds: 2) { gliding.update(level: 0) }
            check("a new level glides there, not at once", glide > -5.9 && glide < -0.2, db(glide))
            check("…and gets there", near(gliding.appliedForTests ?? -99, 0, 0.01), db(gliding.appliedForTests))
            var boosted = flat
            boosted[6] = 12
            let both = SoundProcessor(gains: boosted, level: -6).offline(frequency: 500)
            check("with the equalizer: its preamp and the level add up (+12 dB at 500 Hz, level −6 dB: −6 dB at 500 Hz)",
                  near(both, -6, 0.5), db(both))

            // C. the meter, on 1 kHz tones through AAC
            let loudPeak = 30000.0, quietPeak = 2000.0
            guard let loud = tone(hz: 1000, seconds: 30, peak: loudPeak), let quiet = tone(hz: 1000, seconds: 30, peak: quietPeak) else {
                check("tones made with afconvert", false)
                finish()
                return
            }
            func listing(_ name: String) -> Listing {
                Listing(source: "jiosaavn", id: "selftest-level-\(name)-\(UUID().uuidString)", title: "Level \(name)",
                        artists: ["Self-Test"], album: nil, duration: 30, popularity: nil, image: nil)
            }
            let loudSong = listing("loud"), quietSong = listing("quiet")
            keys = [loudSong.key, quietSong.key]
            try? FileManager.default.createDirectory(at: AudioCache.shared.folder, withIntermediateDirectories: true)
            try? loud.write(to: AudioCache.shared.path(for: loudSong.key))
            let quietFile = FileManager.default.temporaryDirectory.appending(path: "nn-level-quiet.m4a")
            try? quiet.write(to: quietFile)
            defer { try? FileManager.default.removeItem(at: quietFile) }
            let loudRead = try? LoudnessMeter.measure(file: AudioCache.shared.path(for: loudSong.key))
            let quietRead = try? LoudnessMeter.measure(file: quietFile)
            let loudLevel = 20 * log10(loudPeak / 32768), quietLevel = 20 * log10(quietPeak / 32768)
            check(String(format: "the meter reads each tone at its level through AAC (%.1f and %.1f LUFS)", loudLevel, quietLevel),
                  near(loudRead?.lufs ?? 0, loudLevel, 0.3) && near(quietRead?.lufs ?? 0, quietLevel, 0.3),
                  String(format: "%.2f, %.2f", loudRead?.lufs ?? .nan, quietRead?.lufs ?? .nan))
            let started = Date()
            _ = try? LoudnessMeter.measure(file: quietFile)
            report(String(format: "level: measuring a 30 s song took %.0f ms (a 4-minute song: about 8×)", Date().timeIntervalSince(started) * 1000))

            // D. the player
            UserDefaults.standard.set(500, forKey: "audioCacheMB")
            UserDefaults.standard.set(false, forKey: "autoplay")
            if !player.isMuted { player.toggleMute() }
            leveller.setOn(false)
            @MainActor func heard() async -> Double? {
                _ = chain.liveProcessors.map { $0.takeReading() }               // from now
                try? await Task.sleep(for: .seconds(1.5))
                return chain.liveProcessors.compactMap { $0.takeReading().change }.first
            }
            player.play([Track(best: loudSong, listings: [loudSong], choosingVersion: false)])
            check("(the loud tone plays)", await until(10) { player.isPlaying && player.livePosition > 1 })
            check("off: the song has no tap at all", !player.itemHasTapForTests)

            leveller.setOn(true)
            check("switched on mid-song, the song playing from a file is measured within 2 s",
                  await until(2) { leveller.isMeasured(loudSong.key) })
            check("…and its audio goes through the tap", await until(3) { player.itemHasTapForTests })
            try? await Task.sleep(for: .seconds(1.5))                           // the glide to its level
            let loudChange = await heard()
            let loudOut = (loudRead?.lufs ?? 0) + (loudChange ?? 0)
            check(String(format: "the loud tone plays at −14 LUFS (%+.1f dB)", -14 - (loudRead?.lufs ?? 0)),
                  loudChange != nil && near(loudOut, -14, 0.5), db(loudChange))

            let stored = await AudioCache.shared.store(quiet, for: quietSong.key)
            check("a song stored in the cache (as the next song is) is measured before it plays",
                  stored ? await until(3) { leveller.isMeasured(quietSong.key) } : false)
            player.play([Track(best: quietSong, listings: [quietSong], choosingVersion: false)])
            check("(the quiet tone plays)", await until(10) { player.isPlaying && player.livePosition > 0.3 && player.itemHasTapForTests })
            let quietChange = await heard()
            let quietOut = (quietRead?.lufs ?? 0) + (quietChange ?? 0)
            check(String(format: "the quiet tone plays at −14 LUFS from its start (%+.1f dB): the two, 23.5 dB apart, come out level", -14 - (quietRead?.lufs ?? 0)),
                  quietChange != nil && near(quietOut, -14, 0.5), db(quietChange))
            check("the readings are kept on disk", FileManager.default.fileExists(atPath: Leveller.file.path))

            leveller.setOn(false)
            check("switched off, the song's tap is taken away", await until(3) { !player.itemHasTapForTests })
            if player.isPlaying { player.togglePlayPause() }
            finish()
        }
    }
}
#endif
