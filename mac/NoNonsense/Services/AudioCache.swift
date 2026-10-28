import Foundation

/// Songs' audio kept on this Mac (8 Oct, TICKETS 0b): a song played before starts from its file, with no link lookup
/// and no network. Measured 8 Oct: a cold YouTube click took 0.73–0.93 s to sound (the link, a new connection to
/// YouTube's audio server, the player's own start); from a file a song starts in ~0.15 s. On by default (your choice,
/// 8 Oct), 500 MB (~120 songs); the least recently played go first past the limit. Settings › Footprint shows the size,
/// changes the limit (Off turns it off) and clears it. In Caches: macOS may empty it when the disk is full.
actor AudioCache {
    static let shared = AudioCache()
    static let defaultLimitMB = 500
    /// The limit in bytes; 0 = off.
    static var limit: Int { (UserDefaults.standard.object(forKey: "audioCacheMB") as? Int ?? defaultLimitMB) * 1_000_000 }

    nonisolated let folder: URL = {
        #if DEBUG
        // a self-test's own folder: the test app shares yours, and its eviction check must not empty it
        if let dir = ProcessInfo.processInfo.environment["NN_CACHE_DIR"] { return URL(filePath: dir) }
        #endif
        // the app's own identity: a Debug build (app.nononsense.music.debug) keeps a cache of its own
        let app = Bundle.main.bundleIdentifier ?? "app.nononsense.music"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "\(app)/Audio")
    }()

    /// "ytmusic:J7p4bzqLvCw" → ".../ytmusic_J7p4bzqLvCw.m4a" (the extension tells AVPlayer what the file is)
    nonisolated func path(for key: String) -> URL { folder.appending(path: Self.name(for: key) + ".m4a") }

    /// "ytmusic:J7p4bzqLvCw" → "ytmusic_J7p4bzqLvCw": a song's file name, without its extension. Leveller keeps its
    /// readings by it, so a song in the cache is known by its file alone.
    nonisolated static func name(for key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    /// The song's file, if it is here; marked as just played (eviction goes by that date).
    func file(for key: String) -> URL? {
        guard Self.limit > 0 else { return nil }
        let url = path(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// A whole song, fetched: kept, then the oldest removed past the limit. True when its file is here afterwards.
    @discardableResult
    func store(_ data: Data, for key: String) -> Bool {
        guard Self.limit > 0, !data.isEmpty else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: path(for: key), options: .atomic)
        evict()
        let file = path(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        Task { @MainActor in Leveller.shared.measure(key, file: file) }       // nothing while levelling is off
        NotificationCenter.default.post(name: Self.stored, object: nil, userInfo: ["key": key])
        return true
    }

    /// Posted when a whole song is kept (userInfo "key"): the player can queue it behind the playing one (gapless).
    nonisolated static let stored = Notification.Name("AudioCache.stored")

    /// Every song here: its name (`name(for:)`) and file.
    func contents() -> [(name: String, file: URL)] {
        files().map { ($0.url.deletingPathExtension().lastPathComponent, $0.url) }
    }

    /// A cached file that would not play: gone, so the next play fetches it again.
    func remove(_ key: String) { try? FileManager.default.removeItem(at: path(for: key)) }

    /// Bytes on disk.
    func size() -> Int { files().reduce(0) { $0 + $1.size } }

    func clear() { try? FileManager.default.removeItem(at: folder) }

    /// The least recently played first, until the rest fit the limit (a lowered limit applies at the next store).
    func evict() {
        var all = files().sorted { $0.used < $1.used }
        var total = all.reduce(0) { $0 + $1.size }
        while total > Self.limit, let oldest = all.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
    }

    private func files() -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
    }
}

/// One song's audio, fetched once from its start to its end in bounded ranges (YouTube sends an open-ended request at
/// about playback speed; a bounded one at full speed: 256 KB in ~70 ms, 8 Oct). The player is fed from it as the bytes
/// arrive (BoundedRangeLoader); a seek far past what has arrived is fetched on its own. Complete, it goes to the cache.
actor AudioDownload {
    nonisolated let key: String
    nonisolated let link: URL
    /// False for a download to Downloads: the file goes there, not into the cache too (one copy on disk).
    nonisolated let caches: Bool
    private var data = Data()
    /// The song's file in the cache once it is there: ranges are read from it and the copy in memory goes. Each fetch
    /// kept its whole song in memory until three newer ones pushed it out: 10 to 20 MB, an hour-long mix 60 MB (21 Oct).
    /// Held open, it reads on even if the cache lets the file go meanwhile.
    private var file: FileHandle?
    private var length: Int?
    private var finished = false
    private var failure: Error?
    private var task: Task<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private static let session = URLSession(configuration: .ephemeral)

    init(key: String, link: URL, caches: Bool = true) {
        self.key = key
        self.link = link
        self.caches = caches
        // YouTube's links say the length (`clen`): the player is answered without a request
        length = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "clen" }?.value.flatMap(Int.init)
    }

    /// Starts fetching (once): the first range small, so sound can start, then 1 MB at a time.
    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        wake()
    }

    var isComplete: Bool { finished && failure == nil }

    /// The whole song, once it is all in; nil while fetching, or when the fetch failed or stopped.
    func contents() -> Data? {
        guard finished, failure == nil, let length, data.count >= length else { return nil }
        return data
    }
    var hasFailed: Bool { failure != nil }

    /// Returns once the whole song is in, or the fetch has stopped (failed or cancelled).
    func whole() async {
        start()
        while !finished, !Task.isCancelled { await withCheckedContinuation { waiting.append($0) } }
    }

    /// The whole file's length (asks for the first range when the link does not say).
    func totalLength() async throws -> Int {
        start()
        while length == nil {
            if let failure { throw failure }
            if finished { break }
            await withCheckedContinuation { waiting.append($0) }
        }
        return length ?? data.count
    }

    /// Bytes `from`…`to`, both included, as soon as the first of them has arrived (possibly fewer than asked);
    /// empty past the end.
    func bytes(_ from: Int, _ to: Int) async throws -> Data {
        start()
        while true {
            if let file, let length {
                guard from < length else { return Data() }
                try file.seek(toOffset: UInt64(from))
                return try file.read(upToCount: min(to + 1, length) - from) ?? Data()
            }
            if data.count > from { return data.subdata(in: from ..< min(to + 1, data.count)) }
            if let failure { throw failure }
            if finished || Task.isCancelled { return Data() }
            // a seek far ahead: fetched on its own, not waited for
            if from > data.count + 2 * BoundedRangeLoader.range { return try await Self.fetch(link, from: from, to: to).data }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func run() async {
        var size = BoundedRangeLoader.firstRange
        var retries = 0
        // the whole song's room at once, when its length is known: grown 1 MB at a time, the buffer was copied as it
        // doubled and could end up to twice the song
        if let length { data.reserveCapacity(length) }
        while !Task.isCancelled {
            let from = data.count
            if let length, from >= length { break }
            do {
                let piece = try await Self.fetch(link, from: from, to: from + size - 1)
                if length == nil, let total = piece.total {
                    length = total
                    data.reserveCapacity(total)
                }
                if piece.data.isEmpty { break }
                data.append(piece.data)
                retries = 0
                wake()
            } catch {
                // a dropped connection mid-song: the same range again, twice, before the song counts as failed
                retries += 1
                if retries <= 2, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400 * retries))
                    continue
                }
                failure = error
                break
            }
            size = BoundedRangeLoader.range
        }
        finished = true
        if caches, failure == nil, !Task.isCancelled, let length, data.count >= length,
           await AudioCache.shared.store(data, for: key),
           let stored = try? FileHandle(forReadingFrom: AudioCache.shared.path(for: key)) {
            file = stored
            data = Data()
        }
        wake()
    }

    private func wake() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }

    /// One bounded range: bytes `from` to `to`, both included. `total`: the whole file's length, from Content-Range.
    static func fetch(_ link: URL, from: Int, to: Int) async throws -> (data: Data, total: Int?) {
        var request = URLRequest(url: link, timeoutInterval: 15)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        // past the first byte only a partial answer (206) is the asked range: a 200 there is the whole file again
        guard let status = http?.statusCode, status == 206 || (status == 200 && from == 0) else { throw URLError(.badServerResponse) }
        let total = (http?.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
        return (data, total)
    }
}

/// The songs being fetched: the playing one, the next, and one more (an older one is stopped when a fourth starts).
actor AudioDownloads {
    static let shared = AudioDownloads()
    private var recent: [AudioDownload] = []

    /// The song playing: never the one stopped to make room.
    private var playing: String?

    func download(_ key: String, link: URL) async -> AudioDownload {
        // the same song by the same link: the one already fetching. One that failed is dropped: reusing it failed the
        // retry at once, with the same link (JioSaavn's never change)
        if let i = recent.firstIndex(where: { $0.key == key && $0.link == link }) {
            let known = recent.remove(at: i)
            if await !known.hasFailed {
                recent.append(known)
                return known
            }
        }
        let fresh = AudioDownload(key: key, link: link)
        recent.append(fresh)
        if recent.count > 3, let i = recent.firstIndex(where: { $0.key != playing && $0 !== fresh }) {
            let old = recent.remove(at: i)
            Task { await old.cancel() }
        }
        return fresh
    }

    /// The player started this song: it keeps its fetch while others come and go.
    func play(_ key: String) { playing = key }

    /// Returns when this song's fetch is done, at once when none is running (it played from a file, or never streamed).
    func finished(_ key: String) async {
        guard let running = recent.last(where: { $0.key == key }) else { return }
        await running.whole()
    }
}
