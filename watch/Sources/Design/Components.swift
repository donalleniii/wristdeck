import SwiftUI

// Shared building blocks from the handoff's layout system.

/// Section label: 13 pt bold, tertiary, 6 pt left inset.
struct SectionLabel: View {
    let text: String
    var color: Color = WD.C.textTertiary
    var trailing: String?
    var trailingColor: Color = WD.C.running

    init(_ text: String, color: Color = WD.C.textTertiary, trailing: String? = nil, trailingColor: Color = WD.C.running) {
        self.text = text
        self.color = color
        self.trailing = trailing
        self.trailingColor = trailingColor
    }

    var body: some View {
        HStack {
            Text(text)
                .font(WD.F.sectionLabel)
                .foregroundStyle(color)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(WD.F.sectionLabel)
                    .foregroundStyle(trailingColor)
            }
        }
        .padding(.leading, 6)
    }
}

/// 8 pt status dot with a matching glow. Pulses only while running.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulses: Bool = false
    var pulseDuration: Double = 2

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color, radius: 4)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// The violet primary action pill with its inset top highlight.
struct PrimaryPill<Content: View>: View {
    var height: CGFloat = WD.M.primaryPillHeight
    var radius: CGFloat = WD.R.primaryPill
    var fill: Color = WD.C.violet
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            // Pad first, THEN expand: expanding to .infinity before padding
            // pushes content past the pill and wraps the label.
            HStack(spacing: 12) { content() }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
                // The spec's inset top highlight. Expressed as a gradient in the
                // fill rather than an overlaid 1pt rule, which bleeds past the
                // rounded shape at these radii.
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [fill.lighten(0.10), fill],
                                startPoint: .top,
                                endPoint: .bottom,
                            )
                        )
                )
        }
        .pressable()
    }
}

/// Pill text that must never wrap. watchOS proposes tight widths inside a
/// ScrollView and will happily break "New Claude" across two lines.
struct PillLabel: View {
    let text: String
    var font: Font = WD.F.pillLabel

    init(_ text: String, font: Font = WD.F.pillLabel) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// The circular agent-colored plus badge on the New Claude / New Codex pills.
struct AgentPlusBadge: View {
    let agent: String

    var body: some View {
        ZStack {
            Circle().fill(WD.C.agent(agent))
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WD.C.onAgent(agent))
        }
        .frame(width: 26, height: 26)
    }
}

/// A quiet full-width row on the surface color.
struct SecondaryRow: View {
    let title: String
    let systemImage: String
    var height: CGFloat = WD.M.secondaryRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title).font(WD.F.body)
            }
            .foregroundStyle(WD.C.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(WD.C.surface)
            )
        }
        .pressable()
    }
}

/// Session row: status dot, title, status-colored subtitle, chevron.
struct SessionRow: View {
    let title: String
    let meta: String
    let statusColor: Color
    let pulses: Bool
    var showsChevron: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                StatusDot(color: statusColor, pulses: pulses)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(WD.F.body)
                        .foregroundStyle(WD.C.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(meta)
                        .font(WD.F.meta)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WD.C.textDisabled)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: WD.R.row, style: .continuous)
                    .fill(WD.C.surface)
            )
        }
        .pressable()
    }
}

/// Compact square destination tile, four to a row.
struct NavTile: View {
    let icon: String
    let label: String
    var badge: Int = 0
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint ?? WD.C.textSecondary)
                        .frame(width: 24, height: 20)
                    if badge > 0 {
                        Circle()
                            .fill(WD.C.claude)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                    }
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WD.C.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(WD.C.surface)
            )
        }
        .pressable()
    }
}

/// Filter / variant chip.
struct Chip: View {
    let label: String
    let selected: Bool
    var selectedFill: Color = Color(hex: 0xF5F5F4)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(selected ? Color(hex: 0x1C1917) : WD.C.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: WD.M.chip)
                .background(
                    RoundedRectangle(cornerRadius: WD.R.chip, style: .continuous)
                        .fill(selected ? selectedFill : WD.C.surface)
                )
        }
        .pressable()
    }
}

/// Sticky-feeling header: back chevron, title, clock.
/// watchOS owns the real navigation bar, so this is used inside screens that
/// want the handoff's explicit header treatment.
struct WDHeader: View {
    let title: String
    var onBack: (() -> Void)?

    @State private var now = Date()
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var clock: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: now)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WD.C.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WD.C.surface))
                }
                .pressable()
            }
            Text(title)
                .font(WD.F.headerTitle)
                .foregroundStyle(WD.C.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(clock)
                .font(WD.F.clock)
                .monospacedDigit()
                .foregroundStyle(WD.C.textPrimary)
        }
        .frame(minHeight: WD.M.headerMin)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .onReceive(tick) { now = $0 }
    }
}

/// Standard screen scaffold: black canvas, 16 pt gutters, entrance animation.
struct WDScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WD.M.rowGap) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WD.M.edge)
            .padding(.bottom, WD.M.bottomSafe)
            .springEntrance()
        }
        .background(WD.C.bg)
    }
}
