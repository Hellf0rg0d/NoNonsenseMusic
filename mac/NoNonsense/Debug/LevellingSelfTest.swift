#if DEBUG
import AppKit

/// With `NN_SELFTEST_LEVEL=1` (no internet: tones made here, played from the audio cache): Settings › Playback › Same
/// volume for every song, and the limiter. The gain rules; the processor's gain, its glide and the limiter, offline; the
/// meter on two AAC tones 23.5 dB apart; then the player: no tap while off, the playing song measured when switched on
/// and brought to −14 LUFS, a song stored in the cache measured before it plays and started at its level, and the tap
/// gone when switched off. Muted; the settings it changes are put back.
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
            borrowDefaults(["levelOn", "limiterOn", "crossfeed", "headphoneCorrection", "eqOn", "audioCacheMB", "autoplay"])
            var keys: [String] = []
            @MainActor func finish() {
                leveller.setOn(false)
                leveller.setLimiting(false)
                for key in keys {
                    leveller.setForTests(nil, for: key)
                    Task { await AudioCache.shared.remove(key) }
                }
                returnDefaults()
                report("level: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            Equalizer.shared.setOn(false)
            leveller.setLimiting(false)

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

            // B2. the limiter: a boost keeps its volume, no sample past −1 dBFS, quiet audio untouched
            check("with the limiter, a quiet song is brought all the way up (−20 LUFS, −3 dBFS: +6 dB)",
                  Leveller.gain(Reading(lufs: -20, peak: -3), limiting: true) == 6)
            let limited = SoundProcessor(gains: boosted, limiting: true)
            let limitedChange = limited.offline(frequency: 500)                  // a −12 dBFS tone, +12 dB: 0 dBFS
            check("with the limiter, +12 dB at 500 Hz keeps its volume up to the −1 dBFS ceiling (+11 dB, not 0)",
                  limitedChange > 10 && limitedChange <= 11.1, db(limitedChange))
            check("…and the limiter took the peak down", (limited.limiterDeepestForTests ?? 0) < -0.5, db(limited.limiterDeepestForTests))
            let clean = SoundProcessor(gains: flat, limiting: true)
            let cleanChange = clean.offline(frequency: 1000)
            check("the limiter leaves audio under its ceiling as it is", near(cleanChange, 0, 0.01) && clean.limiterDeepestForTests == 0,
                  "\(db(cleanChange)), deepest \(db(clean.limiterDeepestForTests))")

            // B3. crossfeed (bs2b's numbers): bass reaches the other ear 4.5 dB down, highs stay on their side
            @MainActor func crossfed(_ hz: Double, both: Bool) -> (other: Double, same: Double) {
                let rate = 44_100.0, frames = Int(rate)
                var left = (0..<frames).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
                var right = both ? left : [Float](repeating: 0, count: frames)
                let before = left
                let feed = Crossfeed(sampleRate: rate)
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in feed.process(l.baseAddress!, r.baseAddress!, frames: frames) }
                }
                func power(_ x: [Float]) -> Double {
                    var sum = 0.0
                    for v in x[(frames / 2)...] { sum += Double(v) * Double(v) }
                    return sum
                }
                return (10 * log10(power(right) / power(left)), 10 * log10(power(left) / power(before)))
            }
            let bass = crossfed(100, both: false), treble = crossfed(10_000, both: false), mono = crossfed(60, both: true)
            check("crossfeed: 100 Hz in one ear reaches the other 4.5 dB down", near(bass.other, -4.5, 0.6), db(bass.other))
            check("…10 kHz stays on its side (under −20 dB)", treble.other < -20, db(treble.other))
            check("…and bass in both ears stays as loud", near(mono.same, 0, 0.3), db(mono.same))

            // B4. headphone correction: AutoEq's AirPods Pro file (crinacle's measurement), as fetched
            let airpods = """
                Preamp: -6.0 dB
                Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
                Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
                Filter 3: ON PK Fc 8903 Hz Gain 6.0 dB Q 1.66
                Filter 4: ON PK Fc 183 Hz Gain 2.0 dB Q 0.77
                Filter 5: ON PK Fc 4613 Hz Gain 3.4 dB Q 2.46
                Filter 6: ON HSC Fc 10000 Hz Gain -0.5 dB Q 0.70
                Filter 7: ON PK Fc 1517 Hz Gain -1.0 dB Q 2.33
                Filter 8: ON PK Fc 929 Hz Gain 1.2 dB Q 2.75
                Filter 9: ON PK Fc 44 Hz Gain -0.5 dB Q 2.16
                Filter 10: ON PK Fc 618 Hz Gain -0.5 dB Q 2.86
                """
            let filters = CorrectionFilter.parse(airpods)
            check("a ParametricEQ.txt gives its 10 filters, shelves and peaks", filters.count == 10
                  && filters.first?.kind == .lowShelf && filters[5].kind == .highShelf, "\(filters.count)")
            let curvePeak = SoundProcessor.peak(coefficients: filters.flatMap { $0.coefficients(sampleRate: 44_100) }, sampleRate: 44_100)
            check("its curve peaks where AutoEq says (preamp −6.0 dB: the shelves and peaks are AutoEq's own)",
                  near(curvePeak, 6, 0.1), db(curvePeak))
            let corrected = SoundProcessor(gains: flat, correction: filters)
            let at8k = corrected.offline(frequency: 8903), at514 = corrected.offline(frequency: 514)
            check("in the chain: 8.9 kHz (+6 dB filter) comes out louder than 514 Hz (−4.4 dB filter), under the preamp",
                  at8k > at514 + 6 && at8k <= 0.1, "\(db(at8k)), \(db(at514))")

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

            // E. headphone correction, live from GitHub: the list, then one model's filters, and the tap for it
            let correction = HeadphoneCorrection.shared
            await correction.loadModels()
            check("AutoEq's list of headphones loads (over 5,000 models)", correction.models.count > 5000,
                  "\(correction.models.count)\(correction.problem.map { ", \($0)" } ?? "")")
            if let model = correction.models.first(where: { $0.name == "Apple AirPods Pro" }) ?? correction.models.first {
                await correction.choose(model)
                check("choosing \(model.name) fetches its filters", correction.model == model && correction.filters.count >= 5,
                      "\(correction.filters.count) filters\(correction.problem.map { ", \($0)" } ?? "")")
                check("…and the playing song gets a tap for it", await until(3) { player.itemHasTapForTests })
                await correction.choose(nil)
                check("turned off, the tap goes", await until(3) { !player.itemHasTapForTests })
            }
            if player.isPlaying { player.togglePlayPause() }
            finish()
        }
    }
}
#endif
