#if DEBUG
import AppKit
import AVFoundation

/// With `NN_SELFTEST_LATENCY=1`: where the time goes between pressing play and hearing a song (8 Oct: "everything feels
/// like it is delaying"). For real songs, from YouTube and JioSaavn: the link (cold, then remembered), Apple's player on
/// its own (ready, then the first audio), and the whole path through the app's player. Needs the internet.
/// Found 8 Oct: Apple's player took 0.65–2 s to start a YouTube link (JioSaavn: ~0.25 s) because it asks for the file
/// open-ended ("bytes=0-"), which YouTube throttles to about playback speed; bounded ranges come at full speed.
extension SelfTest {
    private static var startedLatency = false

    static func runLatencyCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_LATENCY"] != nil, !startedLatency else { return }
        startedLatency = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !player.isMuted { player.toggleMute() }
            func ms(_ since: Date) -> String { String(format: "%4.0f ms", Date().timeIntervalSince(since) * 1000) }

            var copies: [Listing] = []
            for query in ["blinding lights the weeknd", "tum hi ho arijit singh", "kesariya arijit singh"] {
                guard let found = try? await API.search(query), let song = found.songs.first else { report("latency: no results for \(query)"); continue }
                for source in ["ytmusic", "jiosaavn"] {
                    if let copy = song.listings.first(where: { $0.source == source }) { copies.append(copy) }
                }
            }

            for copy in copies {
                let name = "\(copy.source == "ytmusic" ? "YouTube " : "JioSaavn") \(copy.title.prefix(18))"
                // 0. what you feel: a click on a song never played this session, through the app's player (link looked up,
                // then the audio), before anything else here has touched that song or its audio server
                await YouTubeLookup.shared.forget(copy.id)
                var t = Date()
                player.play([Track(best: copy, listings: [copy])])
                var clickToSound = "   –   "
                for _ in 0..<400 {
                    if player.livePosition > 0.05 { clickToSound = ms(t); break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                player.togglePlayPause()
                report("latency \(name) | CLICK → SOUND, cold: \(clickToSound)")
                // 1. the link, as the app gets it: cold (YouTube: forgotten first; JioSaavn: the server's cache as it is)
                await YouTubeLookup.shared.forget(copy.id)
                t = Date()
                guard let url = try? await API.audioURL(copy) else { report("latency \(name): NO LINK"); continue }
                let cold = ms(t)
                t = Date()
                _ = try? await API.audioURL(copy)
                let warm = ms(t)
                // 2. Apple's player alone, on that link: ready to play, then the first audio
                let probe = AVPlayer()
                probe.automaticallyWaitsToMinimizeStalling = false
                probe.isMuted = true
                t = Date()
                let item = AVPlayerItem(url: url)
                probe.replaceCurrentItem(with: item)
                probe.play()
                var ready = "   –   ", sound = "   –   "
                for _ in 0..<400 {
                    if ready.hasPrefix(" ") && item.status == .readyToPlay { ready = ms(t) }
                    if probe.currentTime().seconds > 0.05 { sound = ms(t); break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                probe.pause(); probe.replaceCurrentItem(with: nil)
                // 3. the whole path through the app's player, link remembered as it would be on a second play
                t = Date()
                player.play([Track(best: copy, listings: [copy])])
                var heard = "   –   "
                for _ in 0..<400 {
                    if player.livePosition > 0.05 { heard = ms(t); break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                player.togglePlayPause()
                report("latency \(name) | link cold \(cold), remembered \(warm) | AVPlayer ready \(ready), first audio \(sound) | app, play → sound \(heard)")
            }
            report("latency: done")
            NSApp.terminate(nil)
        }
    }
}

/// With `NN_SELFTEST_LOADER=1` (no internet needed): Apple's player through BoundedRangeLoader (TICKETS 0a, 8 Oct), on
/// a 2-minute AAC file made here and served by a local server that logs every Range it is asked for. Sound starts; a
/// seek works; every request was bounded (never `bytes=N-`) and at most 1 MB.
extension SelfTest {
    private static var startedLoader = false

    static func runLoaderCheckIfAsked() {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_LOADER"] != nil, !startedLoader else { return }
        startedLoader = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("loader \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            let dir = FileManager.default.temporaryDirectory.appending(path: "nn-loader-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // a 2-minute tone, stereo 44.1 kHz, as WAV, then AAC in MP4 (what YouTube's itag 140 is)
            let rate = 44100, seconds = 120
            var wav = Data()
            func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
            func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
            let bytes = rate * seconds * 4
            wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); wav.append(contentsOf: Array("WAVEfmt ".utf8))
            u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
            wav.append(contentsOf: Array("data".utf8)); u32(bytes)
            var samples = [Int16](repeating: 0, count: rate * seconds * 2)
            for i in 0..<(rate * seconds) {
                let v = Int16(8000 * sin(Double(i) * 2 * .pi * 440 / Double(rate)))
                samples[2 * i] = v; samples[2 * i + 1] = v
            }
            samples.withUnsafeBytes { wav.append(contentsOf: $0) }
            try? wav.write(to: dir.appending(path: "tone.wav"))
            let convert = Process()
            convert.executableURL = URL(filePath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "256000", dir.appending(path: "tone.wav").path, dir.appending(path: "tone.m4a").path]
            try? convert.run(); convert.waitUntilExit()
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "tone.m4a").path)[.size] as? Int) ?? 0
            report("loader: test file \(size / 1024) KB")
            let server = Process()
            server.executableURL = URL(filePath: "/usr/bin/python3")
            server.currentDirectoryURL = dir
            server.arguments = ["-c", """
            import http.server, os, re
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    size = os.path.getsize('tone.m4a'); asked = self.headers.get('Range', '')
                    open('ranges.log', 'a').write((asked or 'none') + '\\n')
                    m = re.match(r'bytes=(\\d+)-(\\d*)', asked)
                    start = int(m.group(1)) if m else 0
                    end = min(int(m.group(2)) if m and m.group(2) else size - 1, size - 1)
                    self.send_response(206 if m else 200)
                    self.send_header('Content-Type', 'audio/mp4'); self.send_header('Content-Length', str(end - start + 1))
                    if m: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                    self.end_headers()
                    with open('tone.m4a', 'rb') as f: f.seek(start); self.wfile.write(f.read(end - start + 1))
                def log_message(self, *a): pass
            s = http.server.ThreadingHTTPServer(('127.0.0.1', 8798), H)
            open('ready', 'w').close()
            s.serve_forever()
            """]
            // its output nowhere: holding the app's output pipe, a server left running kept the test from ever ending
            // (8 Oct). Stopped before the app quits, below: NSApp.terminate skips a `defer`
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try? server.run()
            // waited for until it listens ("ready" is written once the port is bound), never for a fixed time: the test
            // slept 1 s, and on GitHub's Mac runner Python often took longer to start, so the loader's first request
            // found no server. Its two retries (0.4 s, 0.8 s, for a dropped connection mid-song) hid that up to 2.2 s,
            // as 1–2 s "to sound" on a local file (here: 0.2 s); past it, the item failed with "Could not connect to
            // the server", about two runs in three since 13 Oct (20 Oct, reproduced by delaying the server's start)
            let launched = Date()
            while !FileManager.default.fileExists(atPath: dir.appending(path: "ready").path), server.isRunning,
                  Date().timeIntervalSince(launched) < 30 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let listening = FileManager.default.fileExists(atPath: dir.appending(path: "ready").path)
            check("the test server listens", listening, server.isRunning ? "nothing in 30 s" : "Python stopped: is port 8798 taken?")
            if listening { report(String(format: "loader: test server up in %.0f ms", Date().timeIntervalSince(launched) * 1000)) }

            let toneKey = "selftest:tone-\(UUID().uuidString)"
            let probe = AVPlayer()
            probe.isMuted = true
            probe.automaticallyWaitsToMinimizeStalling = false
            let start = Date()
            probe.replaceCurrentItem(with: AVPlayerItem(asset: BoundedRangeLoader.shared.asset(for: URL(string: "http://127.0.0.1:8798/tone.m4a")!, key: toneKey)))
            probe.play()
            var heard: Double?
            for _ in 0..<500 where heard == nil {
                if probe.currentTime().seconds > 0.05 { heard = Date().timeIntervalSince(start) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("plays through the loader", heard != nil, "no sound in 5 s\(probe.currentItem?.error.map { ": \($0.localizedDescription)" } ?? "")")
            if let heard {
                report(String(format: "loader: play → sound %.0f ms (a local file; YouTube adds the network)", heard * 1000))
                // only on an item that played: on a failed one Apple's seek never returns, and the test hung until
                // the step's alarm, leaving this server and the app's test server running (20 Oct)
                _ = await probe.seek(to: CMTime(seconds: 100, preferredTimescale: 600))
                probe.play()
                try? await Task.sleep(for: .seconds(1.5))
                check("a seek near the end plays on from there", probe.currentTime().seconds > 100, String(format: "%.1f s", probe.currentTime().seconds))
            } else {
                check("a seek near the end plays on from there", false, "not tried: nothing played")
            }
            probe.pause()
            let asked = ((try? String(contentsOf: dir.appending(path: "ranges.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            report("loader: \(asked.count) requests: \(asked.prefix(8).joined(separator: ", "))\(asked.count > 8 ? ", …" : "")")
            let bounded = asked.allSatisfy { line in
                let parts = line.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
                return b - a + 1 <= BoundedRangeLoader.range
            }
            check("every request was a bounded range of at most 1 MB (never open-ended)", !asked.isEmpty && bounded)
            try? FileManager.default.removeItem(at: dir)
            await AudioCache.shared.remove(toneKey)                    // the test app shares your cache: leave nothing
            report("loader: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            server.terminate(); server.waitUntilExit()
            NSApp.terminate(nil)
        }
    }
}
#endif
