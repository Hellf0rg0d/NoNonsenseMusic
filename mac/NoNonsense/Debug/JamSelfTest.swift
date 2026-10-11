#if DEBUG
import AppKit

/// With `NN_SELFTEST_JAM=1` (own test server, needs the internet): start a jam; Play on a song adds it and the host's
/// player (this app) plays it; ⏯ pauses the room and the player with it; a second account (plain HTTP) joins, then
/// the host deliberately hands it the speakers; this Mac stops playing. Leave ends the jam here and gives the player back.
extension SelfTest {
    private static var startedJam = false

    static func runJamCheckIfAsked(player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_JAM"] != nil, !startedJam else { return }
        startedJam = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("jam \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            guard await onOwnTestServer() else { report("jam: this app's own test server needed"); NSApp.terminate(nil); return }
            if !player.isMuted { player.toggleMute() }
            let jam = JamSession.shared
            let me = (try? await API.me())?.username ?? ""

            let songs = (try? await API.search("tum hi ho arijit singh"))?.songs.map(Track.init) ?? []
            guard songs.count >= 2 else { check("songs to play", false); NSApp.terminate(nil); return }
            let song = songs[0]
            // a song playing before the jam carries into it, without stopping or starting over
            player.play([song])
            _ = await until(15) { player.livePosition > 4 }
            let before = player.livePosition
            check("Start a Jam", await jam.start(named: nil) == nil && jam.isHost)
            check("…with an 8-character code", jam.state?.code.count == 8, jam.state?.code ?? "")
            check("…the song that was playing becomes the room's", await until(5) { jam.state?.current?.listing.key == player.playingListing?.key },
                  jam.problem ?? "no state")
            check("…and plays on from where it was", player.isPlaying && player.livePosition >= before - 0.5,
                  String(format: "%.1f s, was %.1f s", player.livePosition, before))
            player.play([songs[1]])
            check("Play on another song adds it to the room's Up Next", await until(5) { jam.state?.queue.contains { $0.listing.key == songs[1].best.key } == true })
            check("Autoplay fills the room's queue when it runs low", await until(15) { (jam.state?.queue.count ?? 0) >= 3 },
                  "\(jam.state?.queue.count ?? 0) queued")
            check("…and Up Next shows the room's queue", await until(3) { frames["upNext.jam"] != nil } || !player.showNowPlaying)
            player.togglePlayPause()
            check("⏯ pauses the room", await until(5) { jam.state?.isPlaying == false })
            check("…and the player", await until(3) { !player.isPlaying })
            player.togglePlayPause()
            check("⏯ again plays both", await until(5) { jam.state?.isPlaying == true && player.isPlaying })

            // A second account joins; only the current host can hand it the speakers.
            let otherName = "test-" + String(UInt32.random(in: 0 ... .max), radix: 16)
            if let other = try? await API.signUp(otherName, testPassword, device: "self-test"), let room = jam.state {
                // friends first: only friends can be invited
                _ = await Social.shared.addFriend(otherName)
                let accept = try? JSONEncoder().encode(["username": me, "action": "accept"])
                _ = await raw("POST", "friends/respond", token: other.token, body: accept)
                // the host invites them: the invite arrives with the room's code, and they join with that code
                check("Invite: the host invites a friend", await jam.invite(otherName) == nil, jam.problem ?? "")
                let inbox = await raw("GET", "notifications", token: other.token)
                let invite = (try? JSONDecoder().decode(NotificationsReply.self, from: inbox.body))?.notifications.first { $0.type == "jam_invite" }
                check("…who gets a notification carrying the code", invite?.payload["code"] == room.code && invite?.from == me,
                      "\(invite?.payload ?? [:])")
                let join = try? JSONEncoder().encode(["code": invite?.payload["code"] ?? room.code])
                let joined = await raw("POST", "jam/join", token: other.token, body: join).status
                check("(the second account joins with it)", joined == 200, "\(joined)")
                check("…and the host sees them at once", await until(3) { jam.state?.members.count == 2 })
                if let member = jam.state?.members.first(where: { $0.username == otherName }) {
                    await jam.remove(member)
                    check("Remove: the host removes them", await until(3) { jam.state?.members.count == 1 }, jam.problem ?? "")
                    let rejoined = await raw("POST", "jam/join", token: other.token, body: join).status
                    let back = await until(3) { jam.state?.members.count == 2 }
                    check("(they join again with the code)", rejoined == 200 && back, "\(rejoined)")
                }
                let handover = try? JSONEncoder().encode(["member_id": other.user.id.uuidString.lowercased()])
                let took = await raw("POST", "jam/\(room.roomID.uuidString.lowercased())/host", token: API.token ?? "", body: handover).status
                check("(and the host hands over the speakers)", took == 204, "\(took)")
                check("this Mac is a remote now: it stops playing", await until(5) { !jam.isHost && !player.isPlaying })
                check("…and the room lists both people", jam.state?.members.count == 2, "\(jam.state?.members.count ?? 0)")
            } else {
                check("sign up a second account", false)
            }
            snap("jam")

            await jam.leave()
            check("Leave: out of the jam, the player is yours again", !jam.inJam && player.jam == nil)
            report("jam: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
