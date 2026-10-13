import Foundation
import Observation

// MARK: - Models (JamState over HTTP and /ws/jam)

nonisolated struct JamMember: Codable, Hashable, Identifiable, Sendable {
    let userID: UUID
    let username: String
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey { case username; case userID = "user_id" }
}

nonisolated struct JamEntry: Codable, Hashable, Identifiable, Sendable {
    let entryID: UUID
    let listing: Listing
    var id: UUID { entryID }
    enum CodingKeys: String, CodingKey { case listing; case entryID = "entry_id" }
}

nonisolated struct JamState: Codable, Equatable, Sendable {
    let roomID: UUID
    let code: String
    let name: String?
    let hostID: UUID
    let members: [JamMember]
    let current: JamEntry?
    let isPlaying: Bool
    let positionSeconds: Double
    let queue: [JamEntry]
    enum CodingKeys: String, CodingKey {
        case code, name, members, current, queue
        case roomID = "room_id"; case hostID = "host_id"; case isPlaying = "is_playing"; case positionSeconds = "position_seconds"
    }
}

/// One control message for the room (JamCommand on the server).
private nonisolated struct JamCommand: Encodable, Sendable {
    let type: String
    var seconds: Double? = nil
    var listings: [Listing]? = nil
    var entryID: UUID? = nil
    /// add: "end", "next" or "now" (Play: at once, the song playing dropped)
    var placement: String? = nil
    /// move: the entry's new place in the room's queue
    var toIndex: Int? = nil
    enum CodingKeys: String, CodingKey { case type, seconds, listings, placement; case entryID = "entry_id"; case toIndex = "to_index" }
}

extension API {
    private struct JamCreate: Encodable { let name: String? }
    private struct JamJoin: Encodable { let code: String }
    private struct JamHost: Encodable {
        let memberID: UUID
        enum CodingKeys: String, CodingKey { case memberID = "member_id" }
    }

    static func createJam(named name: String?) async throws -> JamState {
        try await send("POST", path: "jam", body: JamCreate(name: name))
    }
    static func joinJam(code: String) async throws -> JamState {
        try await send("POST", path: "jam/join", body: JamJoin(code: code))
    }
    static func setJamHost(_ room: UUID, member: UUID) async throws {
        try await sendNoContent("POST", path: "jam/\(room.uuidString.lowercased())/host", body: JamHost(memberID: member))
    }
    private struct JamInvite: Encodable { let username: String }

    static func inviteToJam(_ room: UUID, username: String) async throws {
        try await sendNoContent("POST", path: "jam/\(room.uuidString.lowercased())/invites", body: JamInvite(username: username))
    }
    static func leaveJam(_ room: UUID) async throws {
        try await sendNoContent("POST", path: "jam/\(room.uuidString.lowercased())/leave")
    }
}

// MARK: - The session

/// A jam: one room, one host whose Mac plays, everyone else a remote. While you are in one, the room decides what
/// plays: the player's ⏯ ⏭ ⏮, seeks, and Play on any song become the room's commands (playing a song adds it to the
/// jam), and the host's player follows the room's state as it arrives. One WebSocket carries the commands and the
/// state; it pings every 25 s and the host reports the playhead every 15 s while playing, so an idle jam costs no CPU.
@MainActor
@Observable
final class JamSession {
    static let shared = JamSession()

    private(set) var state: JamState?
    /// The server's last refusal ("Queue is full (200).") or a connection problem, shown in the jam's popover.
    private(set) var problem: String?

    @ObservationIgnored weak var player: Player?
    @ObservationIgnored var me: UUID?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// The entry this player last loaded: a new state with another entry loads that one.
    @ObservationIgnored private var loadedEntry: UUID?
    /// A new room is taking over the song that was playing: until its first state with a song, the player is left alone.
    @ObservationIgnored private var carrying = false
    /// Commands sent before the room's socket is up; sent in order once it is.
    @ObservationIgnored private var outbox: [String] = []
    @ObservationIgnored private var connected = false
    /// Shows a short confirmation in the window ("Added to the jam"); set by the window.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    var isHost: Bool { state != nil && state?.hostID == me }
    /// A member's device plays the room's song in step with the host. Off: it follows silently (friends in one room
    /// would hear an echo). The host always plays.
    var playHere = true { didSet { player?.jamSetSilent(!isHost && !playHere) } }
    var inJam: Bool { state != nil }

    // MARK: joining and leaving

    /// nil when it worked; else why not.
    func start(named name: String?) async -> String? {
        // the song playing now carries into the room, from where it is, and keeps playing (it stopped before)
        let carried = player.flatMap { player in
            player.current.map { (listing: player.playingListing ?? $0.best, at: player.livePosition, playing: player.isPlaying) }
        }
        carrying = carried != nil
        let problem = await enter { try await API.createJam(named: name?.isEmpty == true ? nil : name) }
        if problem == nil, let carried {
            send(JamCommand(type: "add", listings: [carried.listing]))
            if carried.at > 1 { send(JamCommand(type: "seek", seconds: carried.at)) }
            if !carried.playing { send(JamCommand(type: "pause")) }
        } else {
            carrying = false
        }
        return problem
    }

    func join(code: String) async -> String? {
        let typed = code.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !typed.isEmpty else { return "Enter the jam's code." }
        return await enter { try await API.joinJam(code: typed) }
    }

    private func enter(_ request: () async throws -> JamState) async -> String? {
        do {
            let room = try await request()
            leaveLocally()
            apply(room)
            loop = Task { [weak self] in await self?.listen(room.roomID) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func leave() async {
        guard let room = state?.roomID else { return }
        leaveLocally()
        try? await API.leaveJam(room)
    }

    /// Signed out, or another jam: the socket closes and the player is yours again (not stopped: the song plays on).
    func leaveLocally() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = nil
        problem = nil
        loadedEntry = nil
        carrying = false
        radioSeed = nil
        outbox = []
        connected = false
        playHere = true
        player?.jamSetSilent(false)
        player?.jam = nil
    }

    /// The current host chooses which member's Mac plays. A member cannot silently take over somebody else's speakers.
    func giveSpeakers(to member: JamMember) async {
        guard isHost, let room = state?.roomID else { return }
        do { try await API.setJamHost(room, member: member.userID) } catch { problem = error.localizedDescription }
    }

    /// The host removes someone from the room; their app leaves the jam when the server closes their socket.
    func remove(_ member: JamMember) async {
        guard isHost, let room = state?.roomID else { return }
        do {
            try await API.sendNoContent("DELETE", path: "jam/\(room.uuidString.lowercased())/members/\(member.userID.uuidString.lowercased())")
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The host invites a friend: they get a notification with the jam's code. nil when it went out; else why not.
    func invite(_ username: String) async -> String? {
        guard let room = state?.roomID else { return nil }
        do {
            try await API.inviteToJam(room, username: username)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: commands (the player calls these while in a jam)

    func togglePlay() { send(JamCommand(type: state?.isPlaying == true ? "pause" : "play")) }
    func skip() { send(JamCommand(type: "skip")) }
    func seek(to seconds: Double) { send(JamCommand(type: "seek", seconds: max(0, seconds))) }
    enum Placement: String { case end, next, now }

    /// Play (`.now`), Play Next (`.next`) and Add to Queue (`.end`) in a jam: one command each, placed by the server.
    func add(_ tracks: [Track], _ placement: Placement = .end) {
        guard !tracks.isEmpty else { return }
        send(JamCommand(type: "add", listings: tracks.map(\.best), placement: placement.rawValue))
        let what = tracks.count == 1 ? "“\(tracks[0].title)”" : "\(tracks.count) songs"
        let notice = switch placement {
            case .now: "Playing \(what) in the jam"
            case .next: "\(what) plays next in the jam"
            case .end: "Added \(what) to the jam"
        }
        onNotice?(notice)
    }
    func remove(_ entry: JamEntry) { send(JamCommand(type: "remove", entryID: entry.entryID)) }
    func jump(to entry: JamEntry) { send(JamCommand(type: "jump", entryID: entry.entryID)) }
    func move(_ entry: JamEntry, to index: Int) { send(JamCommand(type: "move", entryID: entry.entryID, toIndex: index)) }

    /// The host's song ended: the room moves on (only the host's player plays it, so only the host says so).
    func songEnded() { if isHost { skip() } }

    private func send(_ command: JamCommand) {
        guard let data = try? JSONEncoder().encode(command), let text = String(data: data, encoding: .utf8) else { return }
        problem = nil
        // before the socket is up (a room just made or joined) the command waits instead of being dropped
        guard connected, let socket else { outbox.append(text); return }
        Task { try? await socket.send(.string(text)) }
    }

    /// The socket is up: the commands that waited go out, in order.
    private func flush() {
        guard let socket, !outbox.isEmpty else { return }
        let waiting = outbox
        outbox = []
        Task { for text in waiting { try? await socket.send(.string(text)) } }
    }

    // MARK: Autoplay for the room

    @ObservationIgnored private var radioSeed: String?
    @ObservationIgnored private var radioAsking = false

    /// The room's Autoplay, run by the host alone (one app asks, not every member's): when two songs or fewer are left,
    /// songs like the room's last one are added, as Up Next does outside a jam. Once per seed, and only after an
    /// answer, so a failure is asked again at the next change.
    private func refillIfNeeded(_ room: JamState) {
        guard isHost, Player.autoplay, room.queue.count <= 1, !radioAsking,
              let last = room.queue.last?.listing ?? room.current?.listing, radioSeed != last.key else { return }
        let exclude = ([room.current?.listing].compactMap { $0 }) + room.queue.map(\.listing)
        radioAsking = true
        Task {
            defer { radioAsking = false }
            guard let songs = try? await API.radio(seed: last, exclude: exclude, limit: 10,
                                                  skipRecent: Player.autoplaySkipsRecent), !songs.isEmpty,
                  state?.roomID == room.roomID else { return }
            radioSeed = last.key
            send(JamCommand(type: "add", listings: songs.map { Track($0).best }))
        }
    }

    // MARK: the room's state

    /// A new state: kept, and this Mac's player made to match it. Every member plays the room's song in step (a member
    /// that only controlled the room showed its own last song, paused, while the room played another, 12 Oct); only the
    /// host moves the room on, sends its position and asks for Autoplay.
    private func apply(_ room: JamState) {
        if room != state { state = room }
        refillIfNeeded(room)
        guard let player else { return }
        player.jam = self
        player.jamSetSilent(room.hostID != me && !playHere)
        guard let entry = room.current else {
            if !carrying, player.isPlaying { player.jamFollow(playing: false) }
            loadedEntry = nil
            return
        }
        carrying = false
        // the room's song is the one already playing here (it was carried in): adopted as it is, not loaded again
        if entry.entryID != loadedEntry, entry.listing.key == player.playingListing?.key {
            loadedEntry = entry.entryID
        }
        if entry.entryID != loadedEntry {
            loadedEntry = entry.entryID
            player.jamLoad(Track(best: entry.listing, listings: [entry.listing], choosingVersion: false),
                           at: room.positionSeconds, playing: room.isPlaying)
            return
        }
        if room.isPlaying != player.isPlaying { player.jamFollow(playing: room.isPlaying) }
        // a seek by anyone: the room's playhead and this player's differ by more than a moment
        if abs(player.livePosition - room.positionSeconds) > 2.5 { player.jamFollow(seek: room.positionSeconds) }
    }

    private func listen(_ room: UUID) async {
        var wait: Double = 1
        while !Task.isCancelled, state?.roomID == room {
            if await connectOnce(room) { wait = 1 }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 30)
        }
    }

    private func connectOnce(_ room: UUID) async -> Bool {
        guard let ticket = try? await API.socketTicket(),
              let url = API.socketURL("ws/jam", query: [URLQueryItem(name: "ticket", value: ticket),
                                                       URLQueryItem(name: "room_id", value: room.uuidString.lowercased())])
        else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        let ticker = Task { [weak self] in
            var beats = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                beats += 1
                guard let self else { return }
                if beats % 3 == 0, self.isHost, let player = self.player, player.isPlaying {
                    self.send(JamCommand(type: "position", seconds: player.livePosition))      // every 15 s
                } else if beats % 5 == 0 {
                    try? await task.send(.string("ping"))                                     // every 25 s
                }
            }
        }
        defer { ticker.cancel(); task.cancel(with: .goingAway, reason: nil); connected = false }
        var answered = false
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            if !answered {
                answered = true
                connected = true
                flush()                                        // the commands that waited for the socket
            }
            if case .string(let text) = message { handle(text) }
        }
        // the room closed, or you left on another device: out of the jam here too
        if !Task.isCancelled, case .http(404, _)? = await Self.roomGone(room) { leaveLocally() }
        return answered
    }

    /// GET /jam/{id}: the failure when the room is gone or you are no longer in it; nil when it is still there.
    private static func roomGone(_ room: UUID) async -> API.Failure? {
        do {
            let _: JamState = try await API.get(API.baseURL.appending(path: "jam/\(room.uuidString.lowercased())"))
            return nil
        } catch let failure as API.Failure {
            return failure
        } catch {
            return nil
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let data: JamState?
        let detail: String?
    }

    private func handle(_ text: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else { return }
        switch envelope.type {
        case "state": if let room = envelope.data { apply(room) }
        case "error": problem = envelope.detail
        default: break                         // "pong"; "position" pushes matter only for showing a remote's playhead
        }
    }
}
