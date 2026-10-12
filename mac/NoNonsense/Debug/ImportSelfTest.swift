#if DEBUG
import AppKit

/// With `NN_SELFTEST_IMPORT=1` (own test server, needs the internet): an Exportify CSV (a quoted title with a comma, a
/// Liked Songs file) and a Spotify playlists file are read here, imported by the server, and the liked songs and the
/// new playlist appear in the library.
extension SelfTest {
    static func runImportCheckIfAsked(library: LibraryStore) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_IMPORT"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("import \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            try? await Task.sleep(for: .seconds(3))
            guard await onOwnTestServer() else { report("import: this app's own test server needed"); NSApp.terminate(nil); return }
            if let paths = ProcessInfo.processInfo.environment["NN_IMPORT_FILES"] {
                await realFiles(paths, library: library, check: check)
                report("import: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
                return
            }
            let folder = FileManager.default.temporaryDirectory.appending(path: "nn-import-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let csv = folder.appending(path: "Liked_Songs.csv")
            try? """
            "Track URI","Track Name","Album Name","Artist Name(s)","Release Date","Duration (ms)"
            "spotify:track:1","Blinding Lights","After Hours","The Weeknd","2020-03-20","200040"
            "spotify:track:2","Tum Hi Ho","Aashiqui 2","Mithoon;Arijit Singh","2013-04-06","262000"
            "spotify:track:3","Not A Real Song, Honestly","Nothing","Nobody At All","2020-01-01","180000"
            """.write(to: csv, atomically: true, encoding: .utf8)
            let playlists = folder.appending(path: "Playlist1.json")
            try? #"{"playlists":[{"name":"Road Trip","items":[{"track":{"trackName":"Shape of You","artistName":"Ed Sheeran"}},{"episode":{"name":"a podcast"}}]}]}"#
                .write(to: playlists, atomically: true, encoding: .utf8)

            let groups = (try? SpotifyFile.groups(in: [csv, playlists])) ?? []
            check("the files are read: Liked Songs and one playlist", groups.map(\.name) == [nil, "Road Trip"], "\(groups.map(\.name))")
            check("…a quoted title keeps its comma, and artists split at ;", groups.first?.songs.map(\.title).last == "Not A Real Song, Honestly"
                  && groups.first?.songs[1].artists == ["Mithoon", "Arijit Singh"])
            check("…a podcast episode is skipped", groups.last?.songs.count == 1)

            let importer = SpotifyImporter.shared
            importer.start([csv, playlists], library: library)
            for _ in 0..<120 where !(importer.status?.finished ?? false) && importer.problem == nil { try? await Task.sleep(for: .milliseconds(500)) }
            let status = importer.status
            check("the server finishes the import", status?.finished == true, importer.problem ?? "\(status?.done ?? 0) of \(status?.total ?? 0)")
            check("…finds the three real songs and not the made-up one", status?.added == 3 && status?.missing.count == 1,
                  "\(status?.added ?? 0) added, missing \(status?.missing ?? [])")
            await library.refresh()
            let liked = Set(library.liked.map(\.best.title))
            check("…the liked songs are in Liked Songs", liked.contains("Blinding Lights") && liked.contains("Tum Hi Ho"), "\(liked)")
            check("…and the playlist is in the library", library.ownPlaylists.contains { $0.name == "Road Trip" })
            try? FileManager.default.removeItem(at: folder)
            report("import: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }

    /// `NN_IMPORT_FILES="a.csv|b.csv"`: the owner's own export files, through the same reader and importer as the
    /// buttons. Every file is read; the ones named in `NN_IMPORT_RUN` are imported as new playlists; a YouTube playlist
    /// link (`NN_IMPORT_LINK`) goes into a playlist made first; each result is opened in the window ("SHOT <name>").
    @MainActor
    private static func realFiles(_ paths: String, library: LibraryStore, check: (String, Bool, String) -> Void) async {
        let urls = paths.split(separator: "|").map { URL(filePath: String($0)) }
        var read = 0
        for url in urls {
            let groups = try? SpotifyFile.groups(in: [url])
            if let g = groups?.first {
                read += 1
                report("import file \(url.lastPathComponent): \(g.songs.count) songs, to \(g.name ?? "Liked Songs")")
            } else {
                report("import file \(url.lastPathComponent): not read")
            }
        }
        check("every file is read", read == urls.count, "\(read) of \(urls.count)")
        let all = urls.compactMap { try? SpotifyFile.groups(in: [$0]) }.flatMap { $0 }.flatMap(\.songs)
        if let tyler = all.first(where: { $0.artists.first == "Tyler, The Creator" }) {
            check("an artist with a comma stays one artist", true, "")
            report("import: e.g. \(tyler.title) -> \(tyler.artists)")
        }
        let importer = SpotifyImporter.shared
        func wait(_ seconds: Int) async {
            for _ in 0..<(seconds * 2) where !(importer.status?.finished ?? false) && importer.problem == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let runNames = Set((ProcessInfo.processInfo.environment["NN_IMPORT_RUN"] ?? "").split(separator: "|").map(String.init))
        for url in urls where runNames.contains(url.lastPathComponent) {
            let started = Date()
            importer.start([url], library: library)
            await wait(1800)
            let s = importer.status
            report("import ran \(url.lastPathComponent): \(s?.added ?? 0) of \(s?.total ?? 0) found in \(Int(Date().timeIntervalSince(started))) s")
            for missing in (s?.missing ?? []).prefix(12) { report("import   not found: \(missing)") }
            check("\(url.lastPathComponent) imported", s?.finished == true && (s?.added ?? 0) > 0, importer.problem ?? "")
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            if let id = library.ownPlaylists.first(where: { $0.name == name })?.id {
                NotificationCenter.default.post(name: .selfTestOpen, object: id)
                try? await Task.sleep(for: .seconds(4))
                snap("import-\(name)")
                try? await Task.sleep(for: .seconds(3))
            }
        }
        if let link = ProcessInfo.processInfo.environment["NN_IMPORT_LINK"] {
            await library.createPlaylist(named: "Imported Into Here", adding: nil)
            await library.refresh()
            if let target = library.ownPlaylists.first(where: { $0.name == "Imported Into Here" })?.id {
                importer.start(link: link, into: target, library: library)
                await wait(900)
                let s = importer.status
                report("import ran the YouTube link: \(s?.added ?? 0) of \(s?.total ?? 0) found")
                check("a YouTube playlist link goes into the playlist chosen", (library.details[target]?.items.count ?? 0) > 0,
                      "\(library.details[target]?.items.count ?? 0) songs")
                NotificationCenter.default.post(name: .selfTestOpen, object: target)
                try? await Task.sleep(for: .seconds(4))
                snap("import-youtube-link")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
#endif
