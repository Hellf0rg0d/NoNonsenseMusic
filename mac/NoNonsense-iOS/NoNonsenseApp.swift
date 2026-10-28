import AVFoundation
import SwiftUI

/// The iPhone app: the Mac app's engine (Models, Services) under a phone's own screens. Sign in, then four tabs (Home,
/// Search, Library, Settings) with the song playing in a bar above them; Now Playing opens from it.
@main
struct NoNonsensePhoneApp: App {
    @State private var library: LibraryStore
    @State private var player: Player
    @State private var downloads: DownloadStore
    @State private var account: Account

    init() {
        // music, not a sound effect: plays on with the screen locked and through the silent switch, and stops others
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let library = LibraryStore()
        let downloads = DownloadStore()
        downloads.notify = { [weak library] text, symbol in library?.notify(text, symbol: symbol) }
        let player = Player(library: library, presence: Presence(), downloads: downloads)
        let account = Account()
        account.onEnded = { [weak player, weak library] in
            player?.stop()
            library?.clear()
            Social.shared.stop()
            JamSession.shared.leaveLocally()
        }
        _library = State(initialValue: library)
        _downloads = State(initialValue: downloads)
        _player = State(initialValue: player)
        _account = State(initialValue: account)
    }

    var body: some Scene {
        WindowGroup {
            Gate()
                .environment(account)
                .environment(player)
                .environment(library)
                .environment(downloads)
                .task { await account.start() }
        }
    }
}

/// Signing in, or the app once signed in.
private struct Gate: View {
    @Environment(Account.self) private var account
    @Environment(LibraryStore.self) private var library

    var body: some View {
        switch account.state {
        case .checking: ProgressView()
        case .signedOut: SignInScreen()
        case .signedIn:
            MainTabs()
                .task { await library.refresh(); await library.refreshPlaylists() }
        }
    }
}

private struct MainTabs: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { HomeScreen() }.withMiniPlayer() }
            Tab("Search", systemImage: "magnifyingglass") { NavigationStack { SearchScreen() }.withMiniPlayer() }
            Tab("Library", systemImage: "music.note.list") { NavigationStack { LibraryScreen() }.withMiniPlayer() }
            Tab("Settings", systemImage: "gearshape") { NavigationStack { PhoneSettings() }.withMiniPlayer() }
        }
        .sheet(isPresented: $player.showNowPlaying) { NowPlayingScreen() }
    }
}
