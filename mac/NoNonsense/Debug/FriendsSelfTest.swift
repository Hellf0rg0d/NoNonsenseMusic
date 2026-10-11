#if DEBUG
import AppKit
import Darwin

/// With `NN_SELFTEST_FRIENDS=1` (own test server): a friend request from the app, accepted by a second account over
/// plain HTTP, arrives in the app through the notifications socket (no refresh); the Friends screen shows; removing the
/// friend empties the list; and with the socket open and nothing playing, the app uses (almost) no CPU.
extension SelfTest {
    private static var startedFriends = false

    static func runFriendsCheckIfAsked(account: Account) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_FRIENDS"] != nil, !startedFriends else { return }
        startedFriends = true
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("friends \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                for _ in 0..<Int(seconds * 10) where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                return done()
            }
            try? await Task.sleep(for: .seconds(3))
            guard await onOwnTestServer(), let me = account.user else {
                report("friends: this app's own test server and a test account needed"); NSApp.terminate(nil); return
            }
            let social = Social.shared
            let otherName = "test-" + String(UInt32.random(in: 0 ... .max), radix: 16)
            guard let other = try? await API.signUp(otherName, testPassword, device: "self-test") else {
                check("sign up a second account", false); NSApp.terminate(nil); return
            }

            check("Add Friend sends a request", await social.addFriend(otherName) == nil)
            check("…shown under Sent", social.outgoing.contains { $0.username == otherName })
            check("a username nobody has is refused with the server's reason", await social.addFriend("test-nobody-has-this-name") != nil)

            // the other account accepts, outside the app: the app hears it on its socket
            let body = try? JSONEncoder().encode(["username": me.username, "action": "accept"])
            let status = await raw("POST", "friends/respond", token: other.token, body: body).status
            check("(the second account accepts)", status == 204, "\(status)")
            check("the acceptance arrives live, as a notification", await until(5) {
                social.notifications.contains { $0.type == "friend_accepted" && $0.from == otherName } && social.unread > 0
            }, "\(social.notifications.map(\.type))")
            check("…and they are a friend", await until(3) { social.friends.contains { $0.username == otherName } })

            NotificationCenter.default.post(name: .selfTestOpen, object: Destination.section(.friends))
            check("the Friends screen shows", await until(5) { frames["friends.page"] != nil })
            snap("friends")

            await social.markAllRead()
            let serverUnread = (try? await API.notifications())?.unreadCount
            check("Mark read: no unread left", social.unread == 0 && serverUnread == 0, "\(serverUnread ?? -1)")

            // idle, socket open: CPU over 10 s
            func cpuSeconds() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            }
            try? await Task.sleep(for: .seconds(2))
            let before = cpuSeconds()
            try? await Task.sleep(for: .seconds(10))
            let percent = (cpuSeconds() - before) / 10 * 100
            check("idle with the socket open: under 1% CPU (Debug build)", percent < 1, String(format: "%.2f%%", percent))
            report(String(format: "friends: idle CPU %.2f%%", percent))

            if let friend = social.friends.first(where: { $0.username == otherName }) { await social.remove(friend) }
            check("Remove Friend: gone", !social.friends.contains { $0.username == otherName })

            report("friends: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
            NSApp.terminate(nil)
        }
    }
}
#endif
