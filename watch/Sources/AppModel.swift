import Foundation
import Observation

/// Maps the real bridge data onto the handoff's screen model. Nothing here is
/// invented: sessions come from /sessions, running state and alerts come from
/// /activity, and projects are derived by grouping sessions by folder.
@Observable
@MainActor
final class AppModel {
    /// Shared so the background-refresh delegate can poll without a view.
    static let shared = AppModel()

    enum SessionStatus: String {
        case running, queued, done, killed, paused

        var isRunning: Bool { self == .running }
    }

    struct Session: Identifiable, Equatable, Hashable {
        let id: String
        let agent: String
        let title: String
        let meta: String
        let cwd: String
        let status: SessionStatus
        let lastActivity: Double
    }

    struct Project: Identifiable, Equatable, Hashable {
        var id: String { path }
        let name: String
        let path: String
        let agent: String
        let running: Int
        let doneToday: Int
    }

    struct Alert: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        let when: String
        let severity: Severity
        let turnId: String?
        /// Present when this alert is something you can decide right here.
        let approval: PendingApproval?

        enum Severity { case failure, approval, info }
    }

    struct RecentFolder: Identifiable, Equatable, Hashable {
        var id: String { path }
        let name: String
        let path: String
        let when: String
    }

    private(set) var sessions: [Session] = []
    private(set) var activity: [ActivityItem] = []
    /// Turns that finished recently, newest first, for the proof-of-work strip.
    private(set) var recent: [FinishedItem] = []
    private(set) var loadError: String?
    private(set) var loading = false

    /// The destination for the next new session.
    var agent: String = "claude"
    var folder: RecentFolder?

    private var refreshTask: Task<Void, Never>?

    // MARK: - Derived

    var runningCount: Int { activity.count }

    var recents: [RecentFolder] {
        var seen = Set<String>()
        var out: [RecentFolder] = []
        for session in sessions where !session.cwd.isEmpty {
            guard seen.insert(session.cwd).inserted else { continue }
            out.append(RecentFolder(
                name: (session.cwd as NSString).lastPathComponent,
                path: session.cwd,
                when: Self.relative(session.lastActivity),
            ))
            if out.count >= 8 { break }
        }
        return out
    }

    var lastUsed: RecentFolder? { recents.first }

    var projects: [Project] {
        var byPath: [String: [Session]] = [:]
        for session in sessions where !session.cwd.isEmpty {
            byPath[session.cwd, default: []].append(session)
        }
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        return byPath.map { path, group in
            let running = group.filter { $0.status.isRunning }.count
            let done = group.filter { !$0.status.isRunning && $0.lastActivity >= startOfDay }.count
            // Whichever agent is most represented owns the project's color.
            let claudeCount = group.filter { $0.agent == "claude" }.count
            return Project(
                name: (path as NSString).lastPathComponent,
                path: path,
                agent: claudeCount >= group.count - claudeCount ? "claude" : "codex",
                running: running,
                doneToday: done,
            )
        }
        .sorted { ($0.running, $0.doneToday) > ($1.running, $1.doneToday) }
    }

    func projects(filter: String) -> [Project] {
        filter == "all" ? projects : projects.filter { $0.agent == filter }
    }

    func sessions(inProject path: String) -> [Session] {
        sessions.filter { $0.cwd == path }
    }

    /// Real alerts: approvals actually waiting, plus turns that ended badly.
    var alerts: [Alert] {
        var out: [Alert] = []
        for item in activity {
            for approval in item.pending {
                out.append(Alert(
                    id: approval.approvalId,
                    title: "\(item.agent == "codex" ? "Codex" : "Claude") needs approval",
                    body: approval.summary,
                    when: Self.relative(approval.createdAt),
                    severity: .approval,
                    turnId: item.turnId,
                    approval: approval,
                ))
            }
        }
        return out
    }

    // MARK: - Loading

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshActivity()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func loadSessions() async {
        loading = true
        defer { loading = false }
        do {
            let raw = try await BridgeClient.shared.sessions()
            let runningIds = Set(activity.map(\.sessionId))
            sessions = raw.map { summary in
                Session(
                    id: summary.id,
                    agent: summary.agent,
                    title: summary.label,
                    meta: runningIds.contains(summary.id) ? "working now" : summary.relativeTime,
                    cwd: summary.cwd,
                    status: runningIds.contains(summary.id) ? .running : .done,
                    lastActivity: summary.lastActivity,
                )
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshActivity() async {
        guard let snapshot = try? await BridgeClient.shared.activitySnapshot() else { return }
        if snapshot.active != activity { activity = snapshot.active }
        let finished = snapshot.recent ?? []
        if finished != recent { recent = finished }
        Notifier.shared.announce(alerts)
    }

    /// One-shot poll used by background refresh: fetch, then notify if anything
    /// is waiting on a decision.
    func checkForApprovals() async {
        await AppSetup.configureClient()
        await refreshActivity()
    }

    /// Decides an approval from anywhere in the app, not just the session
    /// screen it came from. Optimistically drops it from the local snapshot so
    /// the card clears immediately; the next poll is authoritative.
    private(set) var deciding: String?

    func decide(_ alert: Alert, allow: Bool) {
        guard let turnId = alert.turnId, let approval = alert.approval, deciding == nil else { return }
        deciding = approval.approvalId
        Haptics.click()
        Task {
            defer { deciding = nil }
            do {
                _ = try await BridgeClient.shared.respond(
                    turnId: turnId, approvalId: approval.approvalId, allow: allow)
                activity = activity.map { item in
                    guard item.turnId == turnId else { return item }
                    return ActivityItem(
                        turnId: item.turnId,
                        agent: item.agent,
                        sessionId: item.sessionId,
                        status: item.status,
                        startedAt: item.startedAt,
                        elapsedMs: item.elapsedMs,
                        pending: item.pending.filter { $0.approvalId != approval.approvalId },
                    )
                }
                Haptics.success()
            } catch {
                Haptics.failure()
            }
        }
    }

    static func relative(_ epochMs: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMs / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
