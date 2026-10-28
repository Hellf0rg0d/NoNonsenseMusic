import SwiftUI

extension View {
    /// The song playing, in a bar at the bottom of a tab, over its content.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom) { MiniPlayer() }
    }
}

/// The bar: cover, title and play/pause; a tap opens Now Playing.
struct MiniPlayer: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Cover(url: track.image, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                PlayPauseButton(size: 22)
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
        }
    }
}

struct PlayPauseButton: View {
    @Environment(Player.self) private var player
    let size: CGFloat

    var body: some View {
        Button { player.togglePlayPause() } label: {
            ZStack {
                if player.isBuffering {
                    ProgressView()
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: size))
                }
            }
            .frame(width: size * 1.6, height: size * 1.6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

/// The big cover, the time, the controls, and what comes next.
struct NowPlayingScreen: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var dragging: Double?

    var body: some View {
        NavigationStack {
            if let track = player.current {
                List {
                    Section {
                        VStack(spacing: 18) {
                            Cover(url: track.image, size: 300)
                                .shadow(radius: 12, y: 6)
                            VStack(spacing: 4) {
                                Text(track.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                                Text(track.artistLine).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            timeline
                            controls
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }
                    if !player.upNext.isEmpty {
                        Section("Up Next") {
                            ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, next in
                                TrackRow(track: next) { player.jump(to: player.index + 1 + i) }
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await library.toggleLike(track) }
                        } label: {
                            Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                        }
                        .accessibilityLabel(library.isLiked(track) ? "Unlike" : "Like")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { player.showNowPlaying = false }
                    }
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
    }

    /// The time, read from the player twice a second while this screen is open; dragging seeks on release.
    private var timeline: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let length = max(player.duration, 1)
            let now = dragging ?? min(player.livePosition, length)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { now }, set: { dragging = $0 }), in: 0...length) { editing in
                    if !editing, let at = dragging { player.seek(to: at); dragging = nil }
                }
                HStack {
                    Text(Self.time(now))
                    Spacer()
                    Text("-" + Self.time(length - now))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
            }
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            PlayPauseButton(size: 34)
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
    }

    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
