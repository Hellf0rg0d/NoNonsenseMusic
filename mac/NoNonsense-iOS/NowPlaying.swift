import AVKit
import SwiftUI

/// The player: cover, title and play/pause; a tap opens Now Playing, a swipe left or right skips. `docked`: on iOS 26's
/// tab bar, which draws the glass itself; otherwise it is a glass bar of its own.
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let docked: Bool

    var body: some View {
        if let track = player.current {
            HStack(spacing: 10) {
                Cover(url: track.image, size: docked ? 32 : 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                PlayPauseButton(size: 20)
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next")
            }
            .padding(.horizontal, docked ? 12 : 14)
            .padding(.vertical, docked ? 0 : 8)
            .modifier(OwnGlass(on: !docked))
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
            .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height) * 1.5 else {
                    if drag.translation.height < -30 { player.showNowPlaying = true }   // a swipe up opens it
                    return
                }
                drag.translation.width < 0 ? player.next() : player.previous()
            })
            .sensoryFeedback(.selection, trigger: track.id)
        }
    }
}

/// The bar's own glass, before iOS 26 (and the material in its shape where there is no glass).
private struct OwnGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.compatGlass(in: RoundedRectangle(cornerRadius: 16), interactive: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        } else {
            content
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

/// The big cover, the time, the controls, and what comes next, over the cover's own colours.
struct NowPlayingScreen: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var colors: [Color]?
    @State private var dragging: Double?
    @State private var swipe: CGFloat = 0
    @State private var queueShown = false
    @AppStorage("movingBackground") private var moving = false

    var body: some View {
        if let track = player.current {
            GeometryReader { geo in
                let side = min(geo.size.width - 48, geo.size.height * 0.46)
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    cover(track, side: side)
                    Spacer(minLength: 16)
                    titleRow(track)
                    timeline.padding(.top, 18)
                    controls.padding(.top, 14)
                    bottomRow.padding(.top, 18)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .foregroundStyle(.white)
            .background { Backdrop(colors: colors, moving: moving) }
            .presentationDragIndicator(.visible)
            .task(id: track.image) {
                guard let url = track.image else { colors = nil; return }
                colors = await ArtworkCache.shared.colorGrid(for: url)
            }
            .sheet(isPresented: $queueShown) { UpNextSheet() }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note")
        }
    }

    /// Rests smaller while paused and springs to full size on play; dragged sideways it follows the finger, and far
    /// enough it skips.
    private func cover(_ track: Track, side: CGFloat) -> some View {
        Cover(url: track.image, size: side)
            .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25), radius: player.isPlaying ? 28 : 14, y: 14)
            .scaleEffect(player.isPlaying ? 1 : 0.86)
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
            .offset(x: swipe)
            .rotationEffect(.degrees(Double(swipe) / 40))
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { swipe = $0.translation.width }
                .onEnded { drag in
                    let far = abs(drag.translation.width) > side * 0.3 || abs(drag.predictedEndTranslation.width) > side * 0.8
                    if far { drag.translation.width < 0 ? player.next() : player.previous() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { swipe = 0 }
                })
            .sensoryFeedback(.impact(weight: .light), trigger: track.id)
            .accessibilityLabel("Cover of \(track.title)")
            .accessibilityHint("Swipe left for the next song, right for the previous")
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.title2.weight(.bold)).lineLimit(1)
                Text(track.artistLine).font(.body).opacity(0.75).lineLimit(1)
            }
            Spacer(minLength: 0)
            let liked = library.isLiked(track)
            Button { Task { await library.toggleLike(track) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: liked)
            .accessibilityLabel(liked ? "Unlike" : "Like")
        }
    }

    /// The time, read from the player twice a second while this screen is open; dragging seeks on release.
    private var timeline: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let length = max(player.duration, 1)
            let now = dragging ?? min(player.livePosition, length)
            VStack(spacing: 4) {
                Slider(value: Binding(get: { now }, set: { dragging = $0 }), in: 0...length) { editing in
                    if !editing, let at = dragging { player.seek(to: at); dragging = nil }
                }
                .tint(.white)
                HStack {
                    Text(Self.time(now))
                    Spacer()
                    Text("-" + Self.time(length - now))
                }
                .font(.caption.monospacedDigit())
                .opacity(0.7)
            }
        }
    }

    private var controls: some View {
        CompatGlassGroup(spacing: 24) {
            HStack {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.title3).opacity(player.isShuffled ? 1 : 0.45)
                }
                .accessibilityLabel(player.isShuffled ? "Shuffle on" : "Shuffle off")
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                    .accessibilityLabel("Previous")
                Spacer()
                Button { player.togglePlayPause() } label: {
                    ZStack {
                        if player.isBuffering {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 34))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 76, height: 76)
                    .compatGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                    .accessibilityLabel("Next")
                Spacer()
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                        .opacity(player.repeatMode == .off ? 0.45 : 1)
                }
                .accessibilityLabel(player.repeatMode == .off ? "Repeat off" : player.repeatMode == .one ? "Repeat one" : "Repeat all")
            }
            .buttonStyle(.plain)
        }
    }

    private var bottomRow: some View {
        HStack {
            RoutePicker().frame(width: 30, height: 30)
                .accessibilityLabel("Output")
            Spacer()
            Button { queueShown = true } label: { Image(systemName: "list.bullet").font(.title3) }
                .buttonStyle(.plain)
                .accessibilityLabel("Up Next")
        }
        .opacity(0.85)
    }

    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// The cover's nine colours as a mesh, darkened so white text reads on any cover. `moving`: the mesh's inner points
/// drift slowly (Settings, experimental: it redraws every frame).
private struct Backdrop: View {
    let colors: [Color]?
    let moving: Bool

    var body: some View {
        let fallback = Array(repeating: Color(white: 0.18), count: 9)
        let grid = (colors?.count == 9 ? colors : nil) ?? fallback
        Group {
            if moving {
                TimelineView(.animation) { context in
                    mesh(grid, at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                mesh(grid, at: 0)
            }
        }
        .overlay(Color.black.opacity(0.32))
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: colors)
    }

    private func mesh(_ colors: [Color], at t: Double) -> MeshGradient {
        let dx = Float(sin(t * 0.35)) * 0.12, dy = Float(cos(t * 0.27)) * 0.12
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: colors)
    }
}

/// AirPlay's own button: where the sound goes (AirPods, a speaker, this iPhone).
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// What plays next: tap to play, drag to reorder, swipe to remove; Autoplay's songs come after yours.
private struct UpNextSheet: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, next in
                    TrackRow(track: next) { player.jump(to: player.index + 1 + i) }
                }
                .onMove { player.moveUpNext(fromOffsets: $0, toOffset: $1) }
                .onDelete { $0.forEach { player.removeFromUpNext(at: $0) } }
            }
            .overlay { if player.upNext.isEmpty { ContentUnavailableView("Nothing up next", systemImage: "list.bullet") } }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
