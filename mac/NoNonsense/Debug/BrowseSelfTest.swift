#if DEBUG
import AppKit
import SwiftUI

/// With `NN_SELFTEST_BROWSE=1` (own test server, needs the internet): one cover per song whichever copy plays, the
/// preferred source, Search's artists and albums, the artist and album pages (also opened by name, as Now Playing and
/// the song menus open them), and pinning an album to Home and unpinning it.
extension SelfTest {
    private static var startedBrowse = false

    static func runBrowseCheckIfAsked(library: LibraryStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_BROWSE"] != nil, !startedBrowse else { return }
        startedBrowse = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("browse \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            guard await onOwnTestServer() else { report("browse: this app's own test server needed"); NSApp.terminate(nil); return }

            // covers and the preferred source: made-up copies, no network
            func copy(_ source: String, _ image: String, explicit: Bool? = nil) -> Listing {
                Listing(source: source, id: "id-\(source)", title: "Song", artists: ["Alex"], album: "Album", duration: 200,
                        popularity: source == "jiosaavn" ? 90 : 10, image: image, explicit: explicit)
            }
            let js = copy("jiosaavn", "https://example.com/js.jpg"), ytm = copy("ytmusic", "https://example.com/ytm.jpg")
            let song = Track(best: js, listings: [js, ytm])
            check("a song's cover is YouTube Music's art, whichever copy plays",
                  song.image?.absoluteString == ytm.image && song.playing(js).image?.absoluteString == ytm.image)
            let compilation = Listing(source: "jiosaavn", id: "id-b", title: "Other", artists: ["Alex"], album: "Hits", duration: 200,
                                      popularity: 5, image: "https://example.com/b.jpg")
            let single = Listing(source: "jiosaavn", id: "id-a", title: "Other", artists: ["Alex"], album: "Other", duration: 200,
                                 popularity: 5, image: "https://example.com/a.jpg")
            check("without the server's cover, the order of the copies does not matter",
                  Track(best: compilation, listings: [compilation, single]).image == Track(best: single, listings: [single, compilation]).image)
            let served = Track(best: compilation, listings: [compilation, single], image: "https://example.com/served.jpg")
            check("the server's cover wins, and stays when another copy plays",
                  served.image?.absoluteString == "https://example.com/served.jpg" && served.playing(single).image == served.image)
            let savedSource = UserDefaults.standard.object(forKey: "preferredSource")
            UserDefaults.standard.set("ytmusic", forKey: "preferredSource")
            check("Preferred Source › YouTube Music plays that copy", Track(best: js, listings: [js, ytm]).best.source == "ytmusic")
            UserDefaults.standard.set("", forKey: "preferredSource")
            check("Automatic keeps the server's pick", Track(best: js, listings: [js, ytm]).best.source == "jiosaavn")
            UserDefaults.standard.set(savedSource, forKey: "preferredSource")

            // the server's cover: the same on every search, and the same once the song is in the library
            let first = try? await API.search("gummo 6ix9ine"), again = try? await API.search("gummo 6ix9ine")
            let cover = first?.songs.first?.image
            check("Search sends each song's cover, the same on every search", cover != nil && again?.songs.first?.image == cover,
                  "\(cover ?? "nil") / \(again?.songs.first?.image ?? "nil")")
            if let gummo = first?.songs.first.map(Track.init) {
                await library.toggleLike(gummo)
                await library.refresh()
                let liked = library.liked.first { $0.isSameSong(as: gummo) }
                check("…and the library keeps that cover", liked?.image == gummo.image, "\(liked?.image?.absoluteString ?? "nil")")
                if liked != nil { await library.toggleLike(gummo) }
            }

            // Home's shelf: it spans the content column, its first cover on the page margin, nothing under the sidebar
            for song in (first?.songs ?? []).prefix(6) { try? await API.event(song.listings, type: "play", position: 0) }
            await library.refresh()
            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.home))
            if await until(8, { frames["home.recentShelf"] != nil && frames["home.cover:0"] != nil }),
               let shelf = frames["home.recentShelf"], let cover = frames["home.cover:0"], let sidebar = frames["sidebar.list"] {
                // the shelf's frame is the page's (the negative padding widens only what is inside it): the scroll
                // area begins one margin left of it, and its first cover sits on the page margin
                let scrollStart = cover.minX - 32
                check("Home's shelf scrolls from the sidebar's edge, never under it",
                      scrollStart >= sidebar.maxX - 1 && scrollStart <= sidebar.maxX + 16, "starts \(scrollStart), sidebar ends \(sidebar.maxX)")
                check("…and its first cover sits on the page margin", abs(cover.minX - shelf.minX) < 1, "cover \(cover.minX), page \(shelf.minX)")
                snap("browse-home")
            } else {
                check("Home shows the recently played shelf", false)
            }

            // a long Genius note: the card keeps a bounded height (the note scrolls, Show More expands it)
            let long = GeniusNote(fragment: "Alex", text: String(repeating: "A long note about the line. ", count: 300), verified: false)
            let card = NSHostingView(rootView: GeniusNoteCard(note: long, url: nil, play: {}))
            card.layoutSubtreeIfNeeded()
            check("a long Genius note keeps the card within the screen", card.fittingSize.height < 560 && card.fittingSize.height > 150,
                  "\(card.fittingSize.height)")

            // Search brings artists and albums
            let reply = try? await API.search("arijit singh")
            let artist = reply?.artists?.first?.best
            let album = reply?.albums?.first?.best
            check("Search finds artists and albums", artist != nil && album != nil,
                  "\(reply?.artists?.count ?? -1) artists, \(reply?.albums?.count ?? -1) albums")

            // the pages
            if let artist {
                frames["artist.page"] = nil
                Navigator.shared.open(.artist(artist))
                check("an artist opens on their page", await until(15) { frames["artist.page"] != nil })
                // the page sits on the window's own surface: its blur view stays under it (a NavigationStack's pushed page
                // replaced the whole column, surface and player bar included)
                func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
                let surfaces = NSApp.windows.compactMap(\.contentView).flatMap(views)
                    .compactMap { $0 as? NSVisualEffectView }.filter { $0.blendingMode == .behindWindow }
                check("…on the window's own surface, not see-through", !surfaces.isEmpty, "\(surfaces.count) surface blurs")
                snap("browse-artist")
            }
            Navigator.shared.path = []
            try? await Task.sleep(for: .seconds(1))
            frames["artist.page"] = nil
            Navigator.shared.open(.artistNamed("Arijit Singh"))
            let named = (try? await API.searchArtists("Arijit Singh"))?.first?.name ?? "none"
            check("…and by name, as Now Playing opens it", await until(15) { frames["artist.page"] != nil }, "search's first: \(named)")
            Navigator.shared.path = []
            try? await Task.sleep(for: .seconds(1))
            if let album {
                frames["album.page"] = nil
                Navigator.shared.open(.album(album))
                check("an album opens on its page", await until(15) { frames["album.page"] != nil })
                snap("browse-album")

                // pin to Home, then unpin
                await library.pin(album)
                let pinned = library.pinned(album)
                check("Pin to Home: a pinned album in your list", pinned != nil && library.pinnedAlbums.count == 1)
                check("…read-only", pinned.map { !$0.canEdit } ?? false)
                if let pinned { await library.unpin(pinned) }
                check("Unpin: gone", library.pinned(album) == nil && library.pinnedAlbums.isEmpty)
            }
            Navigator.shared.path = []
            report("browse: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
