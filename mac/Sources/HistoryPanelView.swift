import SwiftUI

/// The expanded notch surface: hover the notch (or the pill) and the last
/// dozen turns drop down as cards, thumbnail included, each clickable to get
/// back to whatever that turn produced. Styled to read as an extension of the
/// notch, same as the pill.
struct HistoryPanelView: View {
    var monitor: ActivityMonitor

    enum Tab: String, CaseIterable {
        case history = "History"
        case artifacts = "Artifacts"
    }

    @State private var tab: Tab = .history

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            let approvals = monitor.active.flatMap { item in
                (item.pending ?? []).map { (turn: item, approval: $0) }
            }
            if !approvals.isEmpty {
                ForEach(approvals, id: \.approval.approvalId) { waiting in
                    ApprovalRow(
                        agentLabel: waiting.turn.agentLabel,
                        approval: waiting.approval,
                        onAllow: { monitor.decide(turnId: waiting.turn.turnId, approvalId: waiting.approval.approvalId, allow: true) },
                        onDeny: { monitor.decide(turnId: waiting.turn.turnId, approvalId: waiting.approval.approvalId, allow: false) },
                    )
                }
                divider
            }

            if !monitor.active.isEmpty {
                ForEach(monitor.active) { item in
                    ActiveRow(item: item, elapsed: monitor.elapsed)
                }
                divider
            }

            switch tab {
            case .history:
                if monitor.history.isEmpty {
                    emptyNote("No finished turns yet")
                } else {
                    scrollList(rowCount: monitor.history.count) {
                        ForEach(monitor.history) { entry in
                            HistoryRow(entry: entry, monitor: monitor)
                        }
                    }
                }
            case .artifacts:
                let artifacts = monitor.artifacts
                if artifacts.isEmpty {
                    emptyNote("No files produced yet")
                } else {
                    scrollList(rowCount: artifacts.count) {
                        ForEach(artifacts) { artifact in
                            ArtifactRow(artifact: artifact, monitor: monitor)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "applewatch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("WristDeck")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { candidate in
                    Button {
                        tab = candidate
                    } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tab == candidate ? .white : .white.opacity(0.45))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(.white.opacity(tab == candidate ? 0.14 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }

    /// Explicit height, not maxHeight: the host runs under .fixedSize() (the
    /// pills need it), and a fixed-size ScrollView reports its CONTENT height
    /// as ideal, which would balloon the panel past the screen.
    private func scrollList<Rows: View>(rowCount: Int, @ViewBuilder rows: () -> Rows) -> some View {
        ScrollView {
            VStack(spacing: 2) { rows() }
        }
        .frame(height: min(340, max(48, CGFloat(rowCount) * 50)))
    }

    private var statusText: String {
        if !monitor.bridgeReachable { return "bridge offline" }
        let count = monitor.active.count
        return count == 0 ? "idle" : (count == 1 ? "1 running" : "\(count) running")
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 4)
    }
}

/// A parked approval inside the panel, answerable in place.
private struct ApprovalRow: View {
    let agentLabel: String
    let approval: PendingApproval
    let onAllow: () -> Void
    let onDeny: () -> Void

    private let accent = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(agentLabel) · \(approval.summary)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(approval.detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            ApprovalActionButton(symbol: "xmark", label: "Deny", tint: Color(red: 1.0, green: 0.35, blue: 0.35), action: onDeny)
            ApprovalActionButton(symbol: "checkmark", label: "Allow", tint: Color(red: 0.19, green: 0.82, blue: 0.35), action: onAllow)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.07))
        )
        .help("\(approval.detail)\n\(approval.cwd)\nrisk: \(approval.risk)")
    }
}

/// A live turn inside the panel: same information as the working pill.
private struct ActiveRow: View {
    let item: ActivityItem
    let elapsed: TimeInterval

    private var accent: Color {
        item.agent == "codex" ? Color(red: 0.36, green: 0.80, blue: 0.66) : Color(red: 0.85, green: 0.55, blue: 0.30)
    }

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(color: accent)
            Text(item.agentLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(item.status)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(elapsedText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    private var elapsedText: String {
        let total = max(0, Int(elapsed))
        return total < 60 ? "\(total)s" : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One finished turn: thumbnail, headline, meta line, hover actions.
private struct HistoryRow: View {
    let entry: HistoryEntry
    var monitor: ActivityMonitor

    @State private var hovering = false
    @State private var thumb: NSImage?

    private var accent: Color {
        entry.failed ? Color(red: 1.0, green: 0.28, blue: 0.28) : Color(red: 0.19, green: 0.82, blue: 0.35)
    }

    var body: some View {
        HStack(spacing: 9) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.headline)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metaLine)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if hovering {
                actions
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { if entry.hasTarget { monitor.openTurn(entry.turnId) } }
        .help(helpText)
        .task(id: entry.turnId) {
            if entry.hasShot == true { thumb = await monitor.shotImage(entry.turnId) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Proof shot when there is one; otherwise a quiet monogram tile.
    private var thumbnail: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.06))
                    Image(systemName: entry.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.8))
                }
            }
        }
        .frame(width: 58, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if entry.hasShot == true {
                RowActionButton(symbol: "photo", help: "View screenshot") {
                    monitor.openShotInPreview(entry.turnId)
                }
            }
            if entry.hasTarget {
                RowActionButton(symbol: "magnifyingglass", help: "Reveal in Finder") {
                    monitor.reveal(entry)
                }
                RowActionButton(symbol: "arrow.up.forward.app", help: "Open") {
                    monitor.openTurn(entry.turnId)
                }
            }
        }
        .transition(.opacity)
    }

    private var metaLine: String {
        var parts = [entry.agentLabel, Self.timeAgo(entry.finishedDate), Self.durationText(entry.durationMs)]
        if let cost = entry.costUsd, cost > 0 {
            parts.append(String(format: "$%.2f", cost))
        }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines: [String] = []
        if !entry.prompt.isEmpty { lines.append("\u{201C}\(entry.prompt)\u{201D}") }
        if let last = entry.touched.last { lines.append(last) } else if !entry.cwd.isEmpty { lines.append(entry.cwd) }
        return lines.joined(separator: "\n")
    }

    private static func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func durationText(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// One produced file: real Finder icon, name, where it lives, when, by whom.
private struct ArtifactRow: View {
    let artifact: Artifact
    var monitor: ActivityMonitor

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: artifact.path))
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(artifact.folder) · \(artifact.agent) · \(Self.timeAgo(artifact.finishedDate))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)

            if hovering {
                HStack(spacing: 2) {
                    RowActionButton(symbol: "magnifyingglass", help: "Reveal in Finder") {
                        monitor.revealPath(artifact.path)
                    }
                    RowActionButton(symbol: "arrow.up.forward.app", help: "Open") {
                        monitor.openArtifact(artifact.path)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { monitor.openArtifact(artifact.path) }
        .help(artifact.path)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private static func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct RowActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.14 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
