import Foundation
import Observation

/// Bring a library in from Spotify. The files are read here, on this Mac; only each song's title, artists and length go
/// to the server, which finds each song on its sources in the background (POST /import/spotify) and is asked how far it
/// has got. Two kinds of file: Exportify's CSV (one per playlist, "Liked Songs" among them) and Spotify's own data
/// export (YourLibrary.json for liked songs, Playlist1.json… for playlists).
struct SpotifyImportSong: Codable, Sendable {
    let title: String
    let artists: [String]
    let durationMs: Int?
    enum CodingKeys: String, CodingKey { case title, artists; case durationMs = "duration_ms" }
}

struct SpotifyImportGroup: Codable, Sendable {
    /// nil: Liked Songs. Otherwise a new playlist of this name.
    let name: String?
    let songs: [SpotifyImportSong]
}

struct SpotifyImportStatus: Decodable, Sendable {
    let id: UUID
    let total: Int
    let done: Int
    let added: Int
    let missing: [String]
    let finished: Bool
    let failed: String?
}

extension API {
    private struct ImportBody: Encodable { let groups: [SpotifyImportGroup] }

    static func startSpotifyImport(_ groups: [SpotifyImportGroup]) async throws -> SpotifyImportStatus {
        try await send("POST", path: "import/spotify", body: ImportBody(groups: groups))
    }

    static func spotifyImportStatus(_ id: UUID) async throws -> SpotifyImportStatus {
        try await get(baseURL.appending(path: "import/spotify/\(id.uuidString.lowercased())"))
    }
}

// MARK: - reading Spotify's files

enum SpotifyFile {
    struct Unreadable: LocalizedError {
        let file: String
        var errorDescription: String? { "“\(file)” is not a file from Exportify or from Spotify's data download." }
    }

    /// The lists in these files, in the order picked. A list named like Liked Songs goes to your liked songs.
    static func groups(in urls: [URL]) throws -> [SpotifyImportGroup] {
        try urls.flatMap { url in
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let groups = url.pathExtension.lowercased() == "csv" ? exportify(data, name: name) : try json(data)
            guard let groups, !groups.isEmpty else { throw Unreadable(file: url.lastPathComponent) }
            return groups
        }
    }

    /// Exportify: a header row naming the columns ("Track Name", "Artist Name(s)", "Duration (ms)"), one row per song.
    private static func exportify(_ data: Data, name: String) -> [SpotifyImportGroup]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let rows = csvRows(text)
        guard let header = rows.first,
              let title = header.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Track Name" }),
              let artists = header.firstIndex(where: { $0.hasPrefix("Artist Name") }) else { return nil }
        let duration = header.firstIndex(where: { $0.hasPrefix("Duration") })
        let songs = rows.dropFirst().compactMap { row -> SpotifyImportSong? in
            guard row.count > max(title, artists), !row[title].isEmpty else { return nil }
            return SpotifyImportSong(title: row[title],
                                     artists: row[artists].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                     durationMs: duration.flatMap { row.count > $0 ? Int(row[$0]) : nil })
        }
        let plain = name.replacingOccurrences(of: "_", with: " ")
        return [SpotifyImportGroup(name: plain.lowercased().contains("liked") ? nil : plain, songs: songs)]
    }

    /// Spotify's data download: YourLibrary.json ({"tracks": [{"track", "artist"}]}) or a playlists file
    /// ({"playlists": [{"name", "items": [{"track": {"trackName", "artistName"}}]}]}). Neither says a song's length.
    private static func json(_ data: Data) throws -> [SpotifyImportGroup]? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tracks = root["tracks"] as? [[String: Any]] {
            let songs = tracks.compactMap { t -> SpotifyImportSong? in
                guard let title = t["track"] as? String, !title.isEmpty else { return nil }
                return SpotifyImportSong(title: title, artists: [t["artist"] as? String].compactMap { $0 }, durationMs: nil)
            }
            return [SpotifyImportGroup(name: nil, songs: songs)]
        }
        if let playlists = root["playlists"] as? [[String: Any]] {
            return playlists.compactMap { p -> SpotifyImportGroup? in
                guard let name = p["name"] as? String, !name.isEmpty else { return nil }
                let songs = (p["items"] as? [[String: Any]] ?? []).compactMap { item -> SpotifyImportSong? in
                    guard let t = item["track"] as? [String: Any], let title = t["trackName"] as? String, !title.isEmpty
                    else { return nil }                                   // podcast episodes and local files: skipped
                    return SpotifyImportSong(title: title, artists: [t["artistName"] as? String].compactMap { $0 }, durationMs: nil)
                }
                return songs.isEmpty ? nil : SpotifyImportGroup(name: name, songs: songs)
            }
        }
        return nil
    }

    /// RFC 4180: fields split by commas, a quoted field may hold commas, line breaks and doubled quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = text.makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," { row.append(field); field = "" }
                            else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

// MARK: - the import

@MainActor @Observable
final class SpotifyImporter {
    static let shared = SpotifyImporter()

    /// The running or last import, as the server last reported it.
    private(set) var status: SpotifyImportStatus?
    private(set) var problem: String?
    var running: Bool { status.map { !$0.finished } ?? false }

    func start(_ urls: [URL], library: LibraryStore) {
        problem = nil
        let groups: [SpotifyImportGroup]
        do {
            groups = try SpotifyFile.groups(in: urls)
        } catch {
            problem = error.localizedDescription
            return
        }
        Task {
            do {
                status = try await API.startSpotifyImport(groups)
            } catch {
                problem = error.localizedDescription
                return
            }
            await follow(library: library)
        }
    }

    /// Asks every 2 s until the server says it has finished, then shows the library as it now is.
    private func follow(library: LibraryStore) async {
        while let current = status, !current.finished {
            try? await Task.sleep(for: .seconds(2))
            if let next = try? await API.spotifyImportStatus(current.id) { status = next }
        }
        await library.refresh()
        if let status {
            let missing = status.total - status.added
            library.notify(missing == 0 ? "Imported all \(status.added) songs from Spotify"
                           : "Imported \(status.added) of \(status.total) songs from Spotify; \(missing) not found",
                           symbol: "square.and.arrow.down.fill")
        }
    }
}
