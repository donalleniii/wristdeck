import SwiftUI

/// 01 Home — launch a new session, or resume a running one.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var route: Route?

    private enum Route: Hashable {
        case speak(agent: String, folder: AppModel.RecentFolder)
        case session(id: String, agent: String, title: String)
        case projects
        case actions
        case alerts
        case settings
    }

    var body: some View {
        WDScreen {
            // Anything waiting on you sits ABOVE everything else, with the
            // buttons right there. Previously an approval was only reachable
            // from the session that raised it, so coming back to the app showed
            // no way to answer.
            if !model.alerts.isEmpty {
                SectionLabel(
                    "Waiting on you",
                    color: WD.C.claude,
                    trailing: "\(model.alerts.count)",
                    trailingColor: WD.C.claude,
                )
                ForEach(model.alerts) { alert in
                    if let approval = alert.approval {
                        ApprovalCard(
                            approval: approval,
                            queuePosition: (model.alerts.firstIndex(of: alert) ?? 0) + 1,
                            queueTotal: model.alerts.count,
                            busy: model.deciding != nil,
                        ) { allow in
                            model.decide(alert, allow: allow)
                        }
                    }
                }
            }

            SectionLabel("Start new")

            PrimaryPill { start("claude") } content: {
                AgentPlusBadge(agent: "claude")
                PillLabel("New Claude")
            }
            PrimaryPill { start("codex") } content: {
                AgentPlusBadge(agent: "codex")
                PillLabel("New Codex")
            }

            // Proof of work: what the Mac looked like when the last task
            // finished, so "done" is something you can see rather than trust.
            if let latest = model.recent.first, latest.showsProof {
                SectionLabel("Just finished").padding(.top, 14)
                ProofShot(
                    turnId: latest.turnId,
                    caption: latest.summary.isEmpty ? nil : latest.summary,
                )
                .id(latest.turnId)
            }

            SectionLabel(
                "Running now",
                trailing: "\(model.runningCount) live",
            )
            .padding(.top, 14)

            // Skeletons rather than a spinner: the list keeps its shape while
            // loading, so nothing jumps when real rows arrive.
            if model.sessions.isEmpty && model.loading {
                ForEach(0..<3, id: \.self) { _ in BrandSkeleton(height: 62) }
            }

            ForEach(Array(model.sessions.prefix(6).enumerated()), id: \.element.id) { index, session in
                SessionRow(
                    title: session.title,
                    meta: session.meta,
                    statusColor: color(for: session.status),
                    pulses: session.status.isRunning,
                ) {
                    route = .session(id: session.id, agent: session.agent, title: session.title)
                }
                .staggered(index)
            }

            // Four stacked 50pt rows cost a full screen of scrolling. One row of
            // tiles keeps every destination reachable without the scroll.
            HStack(spacing: 8) {
                NavTile(icon: "bolt.fill", label: "Actions") { route = .actions }
                NavTile(icon: "folder", label: "Projects") { route = .projects }
                NavTile(
                    icon: "bell.fill",
                    label: "Alerts",
                    badge: model.alerts.count,
                    tint: model.alerts.isEmpty ? nil : WD.C.claude,
                ) { route = .alerts }
                NavTile(icon: "gearshape.fill", label: "Settings") { route = .settings }
            }
            .padding(.top, 10)

            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(WD.F.meta)
                    .foregroundStyle(WD.C.alert)
                    .padding(.top, 8)
            }
        }
        .navigationTitle("WristDeck")
        .navigationDestination(item: $route) { destination(for: $0) }
        .animation(.wdEnter, value: model.sessions)
        .animation(.wdSnap, value: model.runningCount)
        .animation(.wdSettle, value: model.alerts)
        .task { await model.loadSessions() }
        .refreshable { await model.loadSessions() }
    }

    /// Straight into dictation. The folder defaults to wherever you were last;
    /// changing it lives below the fold on the Speak screen.
    private func start(_ agent: String) {
        model.agent = agent
        Haptics.click()
        let folder = model.folder
            ?? model.lastUsed
            ?? AppModel.RecentFolder(name: "Mac home folder", path: "", when: "default")
        model.folder = folder
        route = .speak(agent: agent, folder: folder)
    }

    private func color(for status: AppModel.SessionStatus) -> Color {
        switch status {
        case .running: return WD.C.running
        case .queued, .paused: return WD.C.queued
        case .done, .killed: return WD.C.textTertiary
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .speak(let agent, let folder):
            SpeakView(agent: agent, folder: folder)
        case .session(let id, let agent, let title):
            SessionView(sessionId: id, agent: agent, title: title)
        case .projects:
            ProjectsView()
        case .actions:
            QuickActionsView()
        case .alerts:
            AlertsView()
        case .settings:
            SettingsView()
        }
    }
}
