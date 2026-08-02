import SwiftUI

/// 07 Quick actions — one tap across both systems.
struct QuickActionsView: View {
    @Environment(AppModel.self) private var model
    @State private var toast = "Runs on both Claude and Codex"
    @State private var route: Route?

    private enum Route: Hashable {
        case workIn(agent: String)
        case alerts
        case lastSession(id: String, agent: String, title: String)
    }

    var body: some View {
        WDScreen {
            PrimaryPill(height: WD.M.actionPill, radius: WD.M.actionPill / 2) {
                model.agent = "claude"
                route = .workIn(agent: "claude")
            } content: {
                Image(systemName: "plus").frame(width: 22).foregroundStyle(.white)
                Text("New Claude").font(WD.F.row).foregroundStyle(.white)
            }

            PrimaryPill(height: WD.M.actionPill, radius: WD.M.actionPill / 2) {
                model.agent = "codex"
                route = .workIn(agent: "codex")
            } content: {
                Image(systemName: "plus").frame(width: 22).foregroundStyle(.white)
                Text("New Codex").font(WD.F.row).foregroundStyle(.white)
            }

            actionRow(title: "Speak to last session", icon: "mic.fill", tint: .white) {
                if let last = model.sessions.first {
                    route = .lastSession(id: last.id, agent: last.agent, title: last.title)
                } else {
                    toast = "No sessions yet"
                }
            }

            actionRow(title: "Stop all running", icon: "pause.fill", tint: WD.C.queued) {
                let count = model.activity.count
                Haptics.failure()
                Task {
                    for item in model.activity {
                        try? await BridgeClient.shared.abort(turnId: item.turnId)
                    }
                }
                toast = count == 0 ? "Nothing was running" : "Stopped \(count) session\(count == 1 ? "" : "s")"
            }

            actionRow(title: "View alerts", icon: "bell.fill", tint: .white) { route = .alerts }

            Text(toast)
                .font(WD.F.meta)
                .foregroundStyle(WD.C.textQuaternary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .navigationTitle("Quick actions")
        .navigationDestination(item: $route) { destination(for: $0) }
    }

    private func actionRow(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(title)
                    .font(WD.F.row)
                    .foregroundStyle(tint == WD.C.queued ? .white : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: WD.M.actionPill)
            .background(
                RoundedRectangle(cornerRadius: WD.M.actionPill / 2, style: .continuous)
                    .fill(WD.C.surface)
            )
        }
        .pressable()
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .workIn(let agent):
            WorkInView(agent: agent)
        case .alerts:
            AlertsView()
        case .lastSession(let id, let agent, let title):
            SessionView(sessionId: id, agent: agent, title: title)
        }
    }
}

/// 08 Alerts — what needs you, ranked. Content is real: anything actually
/// waiting on a tap right now, rather than an invented notification feed.
struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var opened: String?

    var body: some View {
        WDScreen {
            if model.alerts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(WD.C.running)
                    Text("Nothing needs you")
                        .font(WD.F.body)
                        .foregroundStyle(WD.C.textSecondary)
                    Text("Approvals and failures land here.")
                        .font(WD.F.meta)
                        .foregroundStyle(WD.C.textQuaternary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }

            ForEach(model.alerts) { alert in
                // Anything you can decide is decided right here. Previously this
                // screen announced "needs approval" with nothing to tap, which
                // made the whole gate unusable unless you happened to be sitting
                // on the session it came from.
                if let approval = alert.approval {
                    ApprovalCard(
                        approval: approval,
                        queuePosition: (model.alerts.firstIndex(of: alert) ?? 0) + 1,
                        queueTotal: model.alerts.count,
                        busy: model.deciding != nil,
                    ) { allow in
                        model.decide(alert, allow: allow)
                    }
                } else {
                    alertCard(alert)
                }
            }
        }
        .navigationTitle("Alerts")
        .animation(.wdSettle, value: model.alerts)
    }

    @ViewBuilder
    private func alertCard(_ alert: AppModel.Alert) -> some View {
        Group {
            Button { opened = alert.turnId } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(for: alert.severity))
                            .font(.system(size: 16))
                            .foregroundStyle(color(for: alert.severity))
                            .frame(width: 22)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            Text(alert.body)
                                .font(.system(size: 13))
                                .lineSpacing(13 * 0.35)
                                .foregroundStyle(WD.C.bodyMuted)
                            Text(alert.when)
                                .font(WD.F.micro)
                                .foregroundStyle(color(for: alert.severity))
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: WD.R.card, style: .continuous)
                            .fill(alert.severity == .failure ? WD.C.alertSurface : WD.C.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: WD.R.card, style: .continuous)
                                    .strokeBorder(
                                        alert.severity == .failure
                                            ? WD.C.alert.opacity(0.3)
                                            : WD.C.hairline(0.07),
                                        lineWidth: 1,
                                    )
                            )
                    )
            }
            .pressable()
        }
    }

    private func icon(for severity: AppModel.Alert.Severity) -> String {
        switch severity {
        case .failure: return "exclamationmark.triangle.fill"
        case .approval: return "hand.raised.fill"
        case .info: return "bolt.fill"
        }
    }

    private func color(for severity: AppModel.Alert.Severity) -> Color {
        switch severity {
        case .failure: return WD.C.alert
        case .approval: return WD.C.claude
        case .info: return WD.C.running
        }
    }
}
