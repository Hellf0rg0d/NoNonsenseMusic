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
            Tab("Home", systemImage: "house") { NavigationStack { HomeScreen() }.playerBarBefore26() }
            Tab("Library", systemImage: "square.stack") { NavigationStack { LibraryScreen() }.playerBarBefore26() }
            Tab(role: .search) { NavigationStack { SearchScreen() }.playerBarBefore26() }
        }
        .playerAccessory26()
        .sheet(isPresented: $player.showNowPlaying) { NowPlayingScreen() }
    }
}

extension View {
    /// iOS 26: the player on the tab bar (its bottom accessory, glass), and the tab bar shrinking as you scroll down.
    @ViewBuilder
    func playerAccessory26() -> some View {
        if #available(iOS 26, *) {
            self.tabViewBottomAccessory { MiniPlayer(docked: true) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Before iOS 26: the player as a glass bar just above the tab bar, over each tab's content.
    @ViewBuilder
    func playerBarBefore26() -> some View {
        if #available(iOS 26, *) { self } else { safeAreaInset(edge: .bottom) { MiniPlayer(docked: false) } }
    }
}
