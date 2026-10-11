import Foundation

/// Makes the next songs ready before they are played. Two kinds of work, sized to what a press of ⏭ needs:
/// - links: the next two songs of the queue (⏭, and a quick second ⏭) and the top search result (Settings › Footprint
///   › Search), YouTube's looked up on this Mac, JioSaavn's by the server;
/// - the next song's whole audio, into the cache, so ⏭ starts from a file. Only once the playing song's own audio is
///   all in: fetched at once, it competed with the song that had just started.
/// Sent 0.3 s after the queue settles, 1 s after the search does (results change as you type), and only when the list
/// differs from the last one made ready. Autoplay's songs are queue songs: they are made ready the same way.
final class Prefetcher {
    static let shared = Prefetcher()

    private var queuePart: [Listing] = []
    private var searchPart: [Listing] = []
    private var playing: Listing?
    private var lastSent: [String] = []
    private var pending: Task<Void, Never>?

    /// The playing queue moved or changed: these come next, in play order; `playing` is the copy playing now.
    func queueChanged(_ next: [Listing], playing: Listing? = nil) {
        queuePart = Array(next.prefix(2))
        self.playing = playing
        if next.isEmpty { lastSent = [] }                 // a queue that ends (or a sign-out): the next one starts fresh
        schedule()
    }

    /// The search on screen changed (empty when it is cleared or left).
    func searchChanged(_ top: [Listing]) {
        let count = UserDefaults.standard.object(forKey: "searchPrefetch") as? Int ?? Self.searchDefault
        searchPart = Array(top.prefix(max(0, count)))
        schedule(after: .seconds(1))
    }

    /// How many of a search's top results are made ready: 1 (the one you usually click). Was 5 (7 Oct).
    static let searchDefault = 1

    private func schedule(after delay: Duration = .milliseconds(300)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            let list = (queuePart + searchPart).filter { seen.insert($0.key).inserted }
            guard !list.isEmpty, list.map(\.key) != lastSent else { return }
            // YouTube copies are looked up by this Mac (their links carry the asker's IP); JioSaavn's by the server
            let youtube = list.filter { Listing.isYouTube($0.source) }.map(\.id)
            let others = list.filter { !Listing.isYouTube($0.source) }
            if !others.isEmpty { try? await API.prefetch(others) }   // a server without /prefetch answers 404: nothing breaks
            await YouTubeLookup.shared.warm(youtube)
            guard !Task.isCancelled else { return }               // a newer list took over: this one is not marked done
            lastSent = list.map(\.key)
            // the next song whole, once the playing one is all in (or played from a file): never two at once
            if AudioCache.limit > 0, let next = queuePart.first, await AudioCache.shared.file(for: next.key) == nil {
                if let playing { await AudioDownloads.shared.finished(playing.key) }
                guard !Task.isCancelled, let link = try? await API.audioURL(next) else { return }
                await AudioDownloads.shared.download(next.key, link: link).start()
            }
        }
    }
}
