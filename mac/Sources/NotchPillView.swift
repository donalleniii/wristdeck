import SwiftUI

/// The pill that sits under the notch while the watch is driving this Mac.
/// Deliberately dark and rounded so it reads as an extension of the notch
/// itself on machines that have one, and as a floating HUD on those that don't.
struct NotchPillView: View {
    let item: ActivityItem
    let elapsed: TimeInterval
    let extraCount: Int

    private var accent: Color {
        item.agent == "codex" ? Color(red: 0.36, green: 0.80, blue: 0.66) : Color(red: 0.85, green: 0.55, blue: 0.30)
    }

    var body: some View {
        HStack(spacing: 9) {
            PulsingDot(color: accent)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.agentLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    Image(systemName: "applewatch")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    if extraCount > 0 {
                        Text("+\(extraCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Text(item.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 200, alignment: .leading)

            Text(timeString)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
        )
    }

    private var timeString: String {
        let total = max(0, Int(elapsed))
        return total < 60 ? "\(total)s" : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The "Done" pill. Unlike the working pill, this one is clickable: it opens
/// whatever the turn produced, so you land on the thing rather than hunting.
struct NotchDonePillView: View {
    let item: FinishedItem
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    private var accent: Color {
        item.failed ? Color(red: 1.0, green: 0.28, blue: 0.28) : Color(red: 0.19, green: 0.82, blue: 0.35)
    }

    private var duration: String {
        let seconds = Int(item.durationMs / 1000)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.failed ? "\(item.agentLabel) stopped" : "\(item.agentLabel) done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    Image(systemName: "applewatch")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(duration)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(item.summary.isEmpty ? item.targetLabel : item.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 210, alignment: .leading)

            if item.hasTarget {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(hovering ? .white : .white.opacity(0.6))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(accent.opacity(hovering ? 0.7 : 0.32), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { if item.hasTarget { onOpen() } }
        .help(item.hasTarget ? "Open \(item.targetLabel)" : "Nothing to open")
    }
}

/// Slow breathing dot: reads as "working" without demanding attention.
struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 3)
                    .scaleEffect(on ? 1.9 : 1.0)
                    .opacity(on ? 0 : 0.9)
            )
            .animation(.easeOut(duration: 1.25).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
