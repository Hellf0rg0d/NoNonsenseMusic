import SwiftUI

// MARK: - Home

/// What you played lately, and your playlists.
struct HomeScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        List {
            if !library.recent.isEmpty {
                Section("Recently played") {
                    ForEach(Array(library.recent.prefix(10).enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track) { player.play(Array(library.recent.prefix(10)), startAt: i) }
                    }
                }
            }
            if !library.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                    }
                }
            }
            if library.recent.isEmpty && library.playlists.isEmpty {
                ContentUnavailableView("Nothing played yet", systemImage: "music.note", description: Text("Search for a song to start."))
            }
        }
        .navigationTitle("Home")
        .navigationDestination(for: PlaylistSummary.self) { PlaylistScreen(playlist: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { PhoneSettings() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .refreshable { await library.refresh(); await library.refreshPlaylists() }
    }
}

// MARK: - Search

/// Songs as you type, a moment after you stop. A song plays on its own, then Autoplay (as on the Mac).
struct SearchScreen: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var songs: [Track] = []
    @State private var searching = false
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.secondary) }
            ForEach(songs) { track in
                TrackRow(track: track) { player.play([track], source: "search") }
            }
        }
        .overlay { if searching && songs.isEmpty { ProgressView() } }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Songs, artists, albums")
        .task(id: query) {
            let typed = query.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { songs = []; problem = nil; return }
            try? await Task.sleep(for: .milliseconds(350))                    // the rest of the word first
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let found = try await API.search(typed)
                guard !Task.isCancelled else { return }
                songs = found.songs.map(Track.init)
                problem = songs.isEmpty ? "No songs found." : nil
            } catch {
                if !Task.isCancelled { problem = "Couldn't search: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - Library

struct LibraryScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SongsScreen(title: "Liked Songs", tracks: library.liked)
                } label: {
                    Label("Liked Songs", systemImage: "heart.fill")
                }
            }
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    NavigationLink(value: playlist) { PlaylistRow(playlist: playlist) }
                }
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: PlaylistSummary.self) { PlaylistScreen(playlist: $0) }
        .refreshable { await library.refresh(); await library.refreshPlaylists() }
    }
}

/// A list of songs that plays from the one tapped.
struct SongsScreen: View {
    @Environment(Player.self) private var player
    let title: String
    let tracks: [Track]
    var source: String? = nil

    var body: some View {
        List {
            if !tracks.isEmpty {
                Button {
                    player.play(tracks, startAt: 0, source: source)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                TrackRow(track: track) { player.play(tracks, startAt: i, source: source) }
            }
        }
        .navigationTitle(title)
    }
}

struct PlaylistScreen: View {
    @Environment(LibraryStore.self) private var library
    let playlist: PlaylistSummary
    @State private var loaded = false

    var body: some View {
        let tracks = library.details[playlist.id]?.items.map { Track($0.song) } ?? []
        SongsScreen(title: playlist.name, tracks: tracks, source: "playlist:\(playlist.id.uuidString)")
            .overlay { if !loaded && tracks.isEmpty { ProgressView() } }
            .task {
                _ = await library.loadPlaylist(playlist.id)
                loaded = true
            }
    }
}

// MARK: - Rows

struct TrackRow: View {
    @Environment(Player.self) private var player
    let track: Track
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Cover(url: track.image, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(player.current?.id == track.id ? Color.accentColor : .primary)
                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if track.isExplicit { Image(systemName: "e.square.fill").foregroundStyle(.secondary).font(.caption) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PlaylistRow: View {
    let playlist: PlaylistSummary

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: playlist.thumbnail.flatMap(URL.init(string:)), size: 44, symbol: playlist.isAlbum ? "square.stack" : "music.note.list")
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text("\(playlist.songCount) songs").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// A cover from the artwork cache, or a placeholder.
struct Cover: View {
    let url: URL?
    let size: CGFloat
    var symbol = "music.note"
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 8).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ArtworkCache.shared.image(for: url, size: size * 2)
        }
    }
}
