#if DEBUG
import AppKit

/// With `NN_SELFTEST_SHOTS=1` and `NN_SELFTEST_VISIBLE=1` (needs the internet): sets up a test library and opens the
/// screens the README shows, one at a time, printing "SHOT <name>" when each is ready; a script outside the app
/// photographs the window then. A throwaway test account: nothing of yours appears.
extension SelfTest {
    private static var startedShots = false

    static func runShotsIfAsked(account: Account, library: LibraryStore, player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_SHOTS"] != nil, !startedShots else { return }
        startedShots = true
        Task { @MainActor in
            @MainActor func shot(_ name: String, wait: Double = 3) async {
                try? await Task.sleep(for: .seconds(wait))
                report("SHOT \(name)")
                try? await Task.sleep(for: .seconds(2.5))             // the photograph is taken in this pause
            }
            try? await Task.sleep(for: .seconds(4))
            guard await onOwnTestServer(), let me = account.user else { report("shots: test server needed"); NSApp.terminate(nil); return }
            NSApp.activate()
            if !player.isMuted { player.toggleMute() }

            // a library worth showing: liked songs, recent plays, a playlist
            var songs: [Track] = []
            for q in ["arijit singh", "the weeknd", "ap dhillon", "kendrick lamar"] {
                songs += ((try? await API.search(q))?.songs.prefix(4).map(Track.init)) ?? []
            }
            for song in songs.prefix(12) { await library.toggleLike(song) }
            for song in songs.shuffled().prefix(10) { try? await API.event(song.listings, type: "play", position: 0) }
            _ = await library.createPlaylist(named: "Late Night Drive")
            if let list = library.playlists.first { for song in songs.suffix(6) { await library.add(song, to: list) } }
            _ = await library.createPlaylist(named: "Gym")
            if let gym = library.playlists.first(where: { $0.name == "Gym" }) { for song in songs.prefix(5) { await library.add(song, to: gym) } }
            await library.refresh()

            // friends: one accepted, one request waiting
            for (n, accept) in [("sam", true), ("kai", false)] {
                let name = "\(n)-\(String(UInt32.random(in: 0 ... .max), radix: 16).prefix(4))"
                guard let other = try? await API.signUp(name, testPassword, device: "self-test") else { continue }
                if accept {
                    _ = await Social.shared.addFriend(name)
                    _ = await raw("POST", "friends/respond", token: other.token, body: try? JSONEncoder().encode(["username": me.username, "action": "accept"]))
                } else {
                    _ = await raw("POST", "friends/request", token: other.token, body: try? JSONEncoder().encode(["username": me.username]))
                }
            }
            await Social.shared.refresh()

            if let first = songs.first { player.play([first]) }
            let only = ProcessInfo.processInfo.environment["NN_SHOTS_ONLY"]
            if only == nil {
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            await shot("home", wait: 5)
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.search))
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .selfTestSearch, object: "arijit singh")
            await shot("search", wait: 6)
            Navigator.shared.open(.artistNamed("Arijit Singh"))
            await shot("artist", wait: 6)
            if let album = (try? await API.search("starboy the weeknd"))?.albums?.first?.best {
                Navigator.shared.path = []
                Navigator.shared.open(.album(album))
                await shot("album", wait: 6)
            }
            Navigator.shared.path = []
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.friends))
            await shot("friends")

            }
            // Now Playing with timed lyrics, then a translation
            UserDefaults.standard.set("lyrics", forKey: "nowPlayingPanel")
            UserDefaults.standard.set(false, forKey: "lyricsTranslated")
            if let song = (try? await API.search("blinding lights the weeknd"))?.songs.first.map(Track.init) { player.play([song]) }
            player.showNowPlaying = true
            try? await Task.sleep(for: .seconds(4))
            player.seek(to: 52)
            if only == nil { await shot("now-playing", wait: 5) }
            if let song = (try? await API.search("despacito luis fonsi"))?.songs.first.map(Track.init) { player.play([song]) }
            try? await Task.sleep(for: .seconds(4))
            UserDefaults.standard.set(true, forKey: "lyricsTranslated")
            for _ in 0..<150 where frames["lyrics.translation"] == nil { try? await Task.sleep(for: .milliseconds(100)) }
            player.seek(to: 40)
            await shot("lyrics", wait: 2)
            UserDefaults.standard.set(false, forKey: "lyricsTranslated")
            report("shots: done")
            NSApp.terminate(nil)
        }
    }
}
#endif
