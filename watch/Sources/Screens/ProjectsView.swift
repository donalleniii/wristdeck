import SwiftUI

/// 05 Projects — filter by agent, drill into one.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "all"
    @State private var opened: AppModel.Project?

    var body: some View {
        let shown = model.projects(filter: filter)

        WDScreen {
            HStack(spacing: 8) {
                Chip(label: "All", selected: filter == "all") { filter = "all" }
                Chip(label: "Claude", selected: filter == "claude", selectedFill: WD.C.claude) { filter = "claude" }
                Chip(label: "Codex", selected: filter == "codex", selectedFill: WD.C.codex) { filter = "codex" }
            }

            ForEach(shown) { project in
                Button { opened = project } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(WD.C.agent(project.agent))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                                .font(WD.F.row)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(project.running) running · \(project.doneToday) done today")
                                .font(WD.F.meta)
                                .foregroundStyle(WD.C.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WD.C.textDisabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: WD.R.card, style: .continuous)
                            .fill(WD.C.surface)
                    )
                }
                .pressable()
            }

            Text("\(shown.count) of \(model.projects.count) projects shown")
                .font(WD.F.meta)
                .foregroundStyle(WD.C.textQuaternary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .navigationTitle("Projects")
        .navigationDestination(item: $opened) { ProjectView(project: $0) }
    }
}

/// 06 Project overview — stats, its sessions, and a voice CTA.
struct ProjectView: View {
    let project: AppModel.Project

    @Environment(AppModel.self) private var model
    @State private var openedSession: AppModel.Session?
    @State private var startHere = false

    var body: some View {
        WDScreen {
            VStack(alignment: .leading, spacing: 0) {
                Text("PATH")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(WD.C.textTertiary)
                Text(project.path)
                    .font(WD.F.mono12)
                    .foregroundStyle(WD.C.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.top, 4)
                HStack(spacing: 20) {
                    statFigure(project.running, "RUNNING")
                    statFigure(project.doneToday, "DONE TODAY")
                }
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: WD.R.card, style: .continuous)
                    .fill(WD.C.surface)
            )

            SectionLabel("Sessions")

            ForEach(model.sessions(inProject: project.path).prefix(6)) { session in
                SessionRow(
                    title: session.title,
                    meta: session.meta,
                    statusColor: session.status.isRunning ? WD.C.running : WD.C.textTertiary,
                    pulses: session.status.isRunning,
                    showsChevron: false,
                ) { openedSession = session }
            }

            Button { startHere = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                    Text("Start here by voice").font(.system(size: 17, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: WD.M.controlRow)
                .background(
                    RoundedRectangle(cornerRadius: WD.M.controlRow / 2, style: .continuous)
                        .fill(WD.C.violet)
                )
            }
            .pressable()
        }
        .navigationTitle(project.name)
        .navigationDestination(item: $openedSession) { session in
            SessionView(sessionId: session.id, agent: session.agent, title: session.title)
        }
        .navigationDestination(isPresented: $startHere) {
            SpeakView(
                agent: project.agent,
                folder: AppModel.RecentFolder(name: project.name, path: project.path, when: ""),
            )
        }
    }

    private func statFigure(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(WD.F.hero)
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WD.C.textTertiary)
        }
    }
}
