import Foundation
import Network
import Observation

/// Is this Mac online, and does the server answer? The window shows a banner while either is not so, and the player
/// stops instead of trying song after song (with no internet every song failed and the queue cycled, 7 Oct).
/// Online/offline comes from macOS's own network path monitor: told when it changes, no polling.
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var online = true
    private(set) var serverAnswers = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.pathChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "app.nononsense.connectivity"))
    }

    private func pathChanged(_ up: Bool) {
        guard up != online else { return }
        online = up
        if up { Task { await checkServer() } }       // back online: is the server there too?
    }

    /// Asks the server's /health once and remembers the answer.
    @discardableResult
    func checkServer() async -> Bool {
        let answers = await API.health()
        if answers != serverAnswers { serverAnswers = answers }
        if !answers { watch() }
        return answers
    }

    /// A request to the server got no answer at all (not an error reply): show the banner until it answers again.
    func serverDidNotAnswer() {
        guard serverAnswers else { return }
        serverAnswers = false
        watch()
    }

    /// Any answer from the server, whatever its status, proves it is there: the banner and "Can't reach your server"
    /// go as soon as a request gets through.
    func serverAnswered() { if !serverAnswers { serverAnswers = true } }

    @ObservationIgnored private var watching: Task<Void, Never>?

    /// While the server is out of reach, it is asked again every 10 s, so the banner clears by itself when it is back.
    /// Nothing runs while it answers.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while let self, !self.serverAnswers, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if self.online { _ = await self.checkServer() }
            }
            self?.watching = nil
        }
    }
}
