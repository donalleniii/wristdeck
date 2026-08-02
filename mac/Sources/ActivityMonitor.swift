import Foundation
import Observation

struct ActivityItem: Codable, Identifiable, Equatable {
    let turnId: String
    let agent: String
    let status: String
    let startedAt: Double
    let elapsedMs: Double

    var id: String { turnId }

    var agentLabel: String {
        switch agent {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agent.capitalized
        }
    }
}

/// A turn that just finished. The pill stays up as "Done" so you notice, and
/// clicking it opens whatever the agent actually produced.
struct FinishedItem: Codable, Identifiable, Equatable {
    let turnId: String
    let agent: String
    let outcome: String
    let summary: String
    let cwd: String
    let touched: [String]
    let finishedAt: Double
    let durationMs: Double

    var id: String { turnId }
    var failed: Bool { outcome != "done" }

    var agentLabel: String {
        switch agent {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agent.capitalized
        }
    }

    /// What clicking will open, phrased for a human.
    var targetLabel: String {
        if let last = touched.last { return (last as NSString).lastPathComponent }
        if !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return "nothing to open"
    }

    var hasTarget: Bool { touched.last != nil || !cwd.isEmpty }
}

private struct ActivityResponse: Codable {
    let active: [ActivityItem]
    let recent: [FinishedItem]?
}

/// Polls the bridge for in-flight, watch-triggered work.
@Observable
@MainActor
final class ActivityMonitor {
    private(set) var active: [ActivityItem] = []
    private(set) var bridgeReachable = false

    /// The finished turn currently being announced, if any.
    private(set) var finished: FinishedItem?
    /// Turns already announced and dismissed, so a "Done" pill shows once.
    private var acknowledged: Set<String> = []
    private var finishedShownAt: Date?
    private var baselined = false
    private let proof = ProofCapture()

    /// How long "Done" lingers before it gets out of the way.
    private let doneLinger: TimeInterval = 45

    /// Seconds the current run has been going, ticked locally so the pill counts
    /// up smoothly between polls.
    private(set) var elapsed: TimeInterval = 0

    private let session: URLSession
    private var token = ""
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        loadConfig()
    }

    /// Reads the same .env the bridge uses, so there is nothing to configure.
    private func loadConfig() {
        let envPath = ("~/Projects/WristDeck/bridge/.env" as NSString).expandingTildeInPath
        let port = 8787
        if let text = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line.hasPrefix("WRISTDECK_TOKEN=") {
                    token = String(line.dropFirst("WRISTDECK_TOKEN=".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")
    }

    func start() {
        stop()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if let first = self.active.first {
                    self.elapsed = Date().timeIntervalSince1970 - (first.startedAt / 1000)
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        tickTask?.cancel()
        pollTask = nil
        tickTask = nil
    }

    private func pollOnce() async {
        guard let baseURL, !token.isEmpty, let url = URL(string: "/activity", relativeTo: baseURL) else {
            bridgeReachable = false
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                bridgeReachable = false
                return
            }
            bridgeReachable = true
            let decoded = try JSONDecoder().decode(ActivityResponse.self, from: data)
            if decoded.active != active { active = decoded.active }
            applyFinished(decoded.recent ?? [])
        } catch {
            bridgeReachable = false
            if !active.isEmpty { active = [] }
        }
    }

    private func applyFinished(_ recent: [FinishedItem]) {
        // First poll establishes a baseline. Without this the app announces
        // turns that finished before it was launched, cycling through a stale
        // backlog and marking real completions as already-seen.
        if !baselined {
            baselined = true
            acknowledged.formUnion(recent.map(\.turnId))
            return
        }
        // Retire the current announcement once it has had its moment.
        if let shownAt = finishedShownAt, Date().timeIntervalSince(shownAt) > doneLinger {
            if let current = finished { acknowledged.insert(current.turnId) }
            finished = nil
            finishedShownAt = nil
        }
        guard finished == nil else { return }
        // Newest unacknowledged completion wins.
        guard let next = recent.first(where: { !acknowledged.contains($0.turnId) }) else { return }
        finished = next
        finishedShownAt = Date()

        // Proof of work: photograph the screen now that the result is up.
        if let baseURL, !token.isEmpty {
            proof.capture(turnId: next.turnId, baseURL: baseURL, token: token)
        }
    }

    /// Dismisses the current "Done" pill without opening anything.
    func acknowledgeFinished() {
        if let current = finished { acknowledged.insert(current.turnId) }
        finished = nil
        finishedShownAt = nil
    }

    /// Opens what the finished turn produced, then dismisses the pill.
    func openFinished() {
        guard let current = finished, let baseURL, !token.isEmpty else { return }
        guard let url = URL(string: "/turns/\(current.turnId)/open", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task { _ = try? await session.data(for: request) }
        acknowledgeFinished()
    }
}
