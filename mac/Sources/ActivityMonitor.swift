import AppKit
import Foundation
import Observation

/// An action parked on a human decision, mirrored from the bridge. The watch
/// answers these too; whoever taps first wins and the other side is told.
struct PendingApproval: Codable, Identifiable, Equatable {
    let approvalId: String
    let tool: String
    let summary: String
    let detail: String
    let cwd: String
    let risk: String
    let costHint: String?
    let createdAt: Double
    let expiresAt: Double

    var id: String { approvalId }
}

struct ActivityItem: Codable, Identifiable, Equatable {
    let turnId: String
    let agent: String
    let status: String
    let startedAt: Double
    let elapsedMs: Double
    let pending: [PendingApproval]?

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

/// One row of the bridge's persistent ledger (GET /history). Unlike
/// FinishedItem this survives bridge restarts, so it powers the history menu.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let turnId: String
    let agent: String
    let prompt: String
    let summary: String
    let outcome: String
    let cwd: String
    let touched: [String]
    let createdAt: Double
    let finishedAt: Double
    let durationMs: Double
    let costUsd: Double?
    let hasShot: Bool?

    var id: String { turnId }
    var failed: Bool { outcome != "done" }
    var hasTarget: Bool { !touched.isEmpty || !cwd.isEmpty }

    var agentLabel: String {
        switch agent {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agent.capitalized
        }
    }

    /// The line a menu or panel row leads with: what happened, else what was asked.
    var headline: String {
        let text = summary.isEmpty ? prompt : summary
        return text.isEmpty ? "(no summary)" : text
    }

    var finishedDate: Date { Date(timeIntervalSince1970: finishedAt / 1000) }
}

private struct HistoryResponse: Codable {
    let turns: [HistoryEntry]
}

/// One file some turn produced, for the panel's Artifacts tab.
struct Artifact: Identifiable, Equatable {
    let path: String
    let agent: String
    let finishedAt: Double

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    var finishedDate: Date { Date(timeIntervalSince1970: finishedAt / 1000) }
}

/// Polls the bridge for in-flight, watch-triggered work.
@Observable
@MainActor
final class ActivityMonitor {
    private(set) var active: [ActivityItem] = []
    private(set) var bridgeReachable = false

    /// Persistent ledger rows, newest first. Refreshed on launch, after every
    /// completion, and when the menu is about to show.
    private(set) var history: [HistoryEntry] = []

    /// True while the mouse is holding the panel open (hover over the notch,
    /// the pill, or the panel itself). Owned by AppDelegate's hover plumbing.
    var hoverExpanded = false

    /// Set when the user comes back from being away and turns finished in the
    /// meantime. Cleared by tapping or dismissing the catch-up pill.
    struct CatchUp: Equatable {
        let count: Int
        let since: Date
    }

    private(set) var catchUp: CatchUp?
    /// Idle gap that counts as "away". Long enough that reading a doc does not
    /// trigger it, short enough that a coffee run does.
    private let awayThreshold: TimeInterval = 240
    private var awaySince: Date?

    /// Thumbnails for history rows, keyed by turnId. Small images, tiny cache.
    private let shotCache = NSCache<NSString, NSImage>()

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
        refreshHistory()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
        tickTask = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if let first = self.active.first {
                    self.elapsed = Date().timeIntervalSince1970 - (first.startedAt / 1000)
                }
                beat += 1
                if beat % 10 == 0 { self.checkAwayReturn() }
            }
        }
    }

    /// Away detection by real input idle, NOT display sleep/wake: ProofCapture
    /// deliberately wakes the display (caffeinate) while you are away, so wake
    /// events lie. caffeinate asserts activity but synthesizes no HID events,
    /// so the input-idle clock keeps counting honestly.
    private static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .keyDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private func checkAwayReturn() {
        let idle = Self.secondsSinceLastInput()
        if idle >= awayThreshold {
            // Anchor "away" at the LAST input, not at detection time, so turns
            // that finished during the first idle minutes still count.
            if awaySince == nil { awaySince = Date().addingTimeInterval(-idle) }
            return
        }
        guard idle < 3, let since = awaySince else { return }
        awaySince = nil
        let missed = history.filter { $0.finishedDate > since }
        guard !missed.isEmpty else { return }
        // The catch-up pill becomes the single "you're back" surface: swallow
        // any in-flight "Done" announcement of those same turns so the user
        // does not get told twice.
        acknowledged.formUnion(missed.map(\.turnId))
        if let current = finished, acknowledged.contains(current.turnId) {
            finished = nil
            finishedShownAt = nil
        }
        catchUp = CatchUp(count: missed.count, since: since)
    }

    /// Dismisses the catch-up pill (with or without opening the panel).
    func acknowledgeCatchUp() {
        catchUp = nil
    }

    /// The approval most in need of a human, if any. Sitting at the Mac and
    /// raising your wrist to tap "Allow" is silly; the pill handles it here.
    var firstPendingApproval: (turnId: String, approval: PendingApproval)? {
        for item in active {
            if let approval = item.pending?.first { return (item.turnId, approval) }
        }
        return nil
    }

    /// Answers a parked approval with the same endpoint the watch uses; the
    /// bridge's compare-and-set makes a double-tap race harmless.
    func decide(turnId: String, approvalId: String, allow: Bool) {
        guard let baseURL, !token.isEmpty,
              let url = URL(string: "/turns/\(turnId)/approvals/\(approvalId)", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["decision": allow ? "allow" : "deny"])
        Task {
            _ = try? await session.data(for: request)
            // Refresh immediately so the pill clears now, not a poll later.
            await pollOnce()
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
        // The ledger just gained a row; keep the menu current.
        refreshHistory()
    }

    /// Pulls the persistent ledger. Cheap (a few KB), so it is fine to kick
    /// this from menuWillOpen as well as after completions.
    func refreshHistory(limit: Int = 12) {
        guard let baseURL, !token.isEmpty,
              let url = URL(string: "/history?limit=\(limit)", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task { [weak self] in
            guard let self else { return }
            guard let (data, response) = try? await self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(HistoryResponse.self, from: data)
            else { return }
            if decoded.turns != self.history { self.history = decoded.turns }
        }
    }

    /// Opens what a past turn produced (bridge falls back to its ledger for
    /// turns that are no longer in memory).
    func openTurn(_ turnId: String) {
        guard let baseURL, !token.isEmpty,
              let url = URL(string: "/turns/\(turnId)/open", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task { _ = try? await session.data(for: request) }
    }

    /// Selects the turn's product in Finder. Local, no bridge round trip:
    /// reveal only selects, it never launches, so openPath's gate is not needed.
    func reveal(_ entry: HistoryEntry) {
        revealPath(entry.touched.last ?? entry.cwd)
    }

    func revealPath(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Every file any turn touched, newest turn first, deduped, existing only.
    /// This IS the artifacts list: the bridge already records touched paths per
    /// turn, so the gallery falls out of the ledger for free.
    var artifacts: [Artifact] {
        var seen = Set<String>()
        var out: [Artifact] = []
        for entry in history {
            for path in entry.touched.reversed() where !seen.contains(path) {
                seen.insert(path)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                out.append(Artifact(path: path, agent: entry.agentLabel, finishedAt: entry.finishedAt))
            }
        }
        return out
    }

    /// Opens one artifact via the bridge so the executable-extension gate in
    /// openPath stays the single authority on what "open" is allowed to do.
    func openArtifact(_ path: String) {
        guard let baseURL, !token.isEmpty,
              let url = URL(string: "/open-path", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": path])
        Task { _ = try? await session.data(for: request) }
    }

    /// Thumbnail for a history row; nil when the bridge has no shot for it.
    func shotImage(_ turnId: String) async -> NSImage? {
        if let hit = shotCache.object(forKey: turnId as NSString) { return hit }
        guard let baseURL, !token.isEmpty,
              let url = URL(string: "/turns/\(turnId)/shot", relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else { return nil }
        shotCache.setObject(image, forKey: turnId as NSString)
        return image
    }

    /// Full-size proof shot in Preview: fetch once, park in temp, open.
    func openShotInPreview(_ turnId: String) {
        guard let baseURL, !token.isEmpty,
              let url = URL(string: "/turns/\(turnId)/shot", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task {
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wristdeck-shot-previews", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(turnId).png")
            guard (try? data.write(to: file)) != nil else { return }
            NSWorkspace.shared.open(file)
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
        guard let current = finished else { return }
        openTurn(current.turnId)
        acknowledgeFinished()
    }
}
