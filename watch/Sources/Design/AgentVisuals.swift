import SwiftUI

// Custom "the agent is working" visuals, drawn frame by frame with Canvas +
// TimelineView rather than composed from stock spinners. Lottie and Rive both
// declare no watchOS support (they need Core Animation layers watchOS doesn't
// expose), so anything bespoke has to be drawn natively. These are it.
//
// Battery note: TimelineView(.animation) redraws at display cadence. That is
// fine here because the watch dims within seconds and every one of these is
// only mounted while something is genuinely in flight.

/// The signature visual: three arcs orbiting at different speeds and tilts
/// around a core that breathes. Reads as machinery thinking rather than a
/// generic spinner, and it takes the agent's color so Claude and Codex feel
/// like different entities.
struct AgentOrb: View {
    enum Mode {
        case idle     // slow, dim, waiting for you
        case working  // faster, brighter, clearly busy
    }

    var color: Color
    var mode: Mode = .working
    var diameter: CGFloat = 116

    private var speed: Double { mode == .working ? 1 : 0.42 }
    private var intensity: Double { mode == .working ? 1 : 0.5 }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) / 2

                // Core: a soft radial bloom that breathes on a slow sine.
                let breath = 0.5 + 0.5 * sin(t * 1.5 * speed)
                let coreRadius = maxRadius * (0.30 + 0.05 * breath)
                context.fill(
                    Circle().path(in: CGRect(
                        x: center.x - coreRadius, y: center.y - coreRadius,
                        width: coreRadius * 2, height: coreRadius * 2,
                    )),
                    with: .radialGradient(
                        Gradient(colors: [
                            color.opacity(0.42 * intensity * (0.7 + 0.3 * breath)),
                            color.opacity(0),
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: coreRadius,
                    )
                )

                // Three orbits, each a partial arc sweeping at its own rate and
                // squashed on a different axis so they read as 3D rings.
                let orbits: [(radius: CGFloat, rate: Double, sweep: Double, squash: CGFloat, tilt: Double, width: CGFloat)] = [
                    (maxRadius * 0.92, 0.85, 0.30, 0.42, 0.0, 2.4),
                    (maxRadius * 0.74, -1.25, 0.22, 0.90, 1.1, 2.0),
                    (maxRadius * 0.56, 1.75, 0.16, 0.55, 2.2, 1.6),
                ]

                for orbit in orbits {
                    let start = (t * orbit.rate * speed).truncatingRemainder(dividingBy: 2 * .pi)
                    var path = Path()
                    let steps = 44
                    for step in 0...steps {
                        let progress = Double(step) / Double(steps)
                        let angle = start + progress * orbit.sweep * 2 * .pi
                        // Squash then rotate to fake an inclined ring.
                        let rawX = cos(angle) * Double(orbit.radius)
                        let rawY = sin(angle) * Double(orbit.radius) * Double(orbit.squash)
                        let x = rawX * cos(orbit.tilt) - rawY * sin(orbit.tilt)
                        let y = rawX * sin(orbit.tilt) + rawY * cos(orbit.tilt)
                        let point = CGPoint(x: center.x + x, y: center.y + y)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    // Fade along the arc so it trails like a comet.
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [color.opacity(0), color.opacity(0.95 * intensity)]),
                            startPoint: CGPoint(x: center.x - orbit.radius, y: center.y),
                            endPoint: CGPoint(x: center.x + orbit.radius, y: center.y),
                        ),
                        style: StrokeStyle(lineWidth: orbit.width, lineCap: .round)
                    )

                    // A bright head at the leading edge of each arc.
                    let headAngle = start + orbit.sweep * 2 * .pi
                    let hx = cos(headAngle) * Double(orbit.radius)
                    let hy = sin(headAngle) * Double(orbit.radius) * Double(orbit.squash)
                    let head = CGPoint(
                        x: center.x + hx * cos(orbit.tilt) - hy * sin(orbit.tilt),
                        y: center.y + hx * sin(orbit.tilt) + hy * cos(orbit.tilt),
                    )
                    let dot = orbit.width * 1.15
                    context.fill(
                        Circle().path(in: CGRect(
                            x: head.x - dot, y: head.y - dot, width: dot * 2, height: dot * 2)),
                        with: .color(color.opacity(intensity))
                    )
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .accessibilityHidden(true)
    }
}

/// A light that travels around a rounded rectangle's border. Used to frame the
/// console while output is streaming, so the whole panel reads as live.
struct TracingBorder: View {
    var color: Color
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 1.6
    /// Fraction of the perimeter the moving segment covers.
    var segment: CGFloat = 0.22
    var period: Double = 2.6

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t / period).truncatingRemainder(dividingBy: 1))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .trim(from: phase, to: phase + segment)
                .stroke(
                    LinearGradient(
                        colors: [color.opacity(0), color, color.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing,
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                // trim past 1.0 wraps, so draw the overflow as a second pass.
                .overlay {
                    if phase + segment > 1 {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .trim(from: 0, to: phase + segment - 1)
                            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// Dots that ripple in a travelling wave rather than blinking in place.
/// Compact enough to sit inline in a status line.
struct WaveDots: View {
    var color: Color
    var count: Int = 5
    var dot: CGFloat = 5
    var amplitude: CGFloat = 3.5
    var period: Double = 1.15

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: dot * 0.85) {
                ForEach(0..<count, id: \.self) { index in
                    let phase = t * (2 * .pi / period) - Double(index) * 0.62
                    let lift = CGFloat(sin(phase))
                    Circle()
                        .fill(color)
                        .frame(width: dot, height: dot)
                        .offset(y: -lift * amplitude)
                        .opacity(0.45 + 0.55 * Double((lift + 1) / 2))
                        .scaleEffect(0.82 + 0.18 * (lift + 1) / 2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Concentric rings pushing outward, for the moment a prompt is dispatched.
struct PulseRings: View {
    var color: Color
    var diameter: CGFloat = 90
    var ringCount: Int = 3
    var period: Double = 1.8

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<ringCount, id: \.self) { index in
                    let offset = Double(index) / Double(ringCount)
                    let progress = ((t / period) + offset).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity(0.9 * (1 - progress)), lineWidth: 2)
                        .scaleEffect(0.35 + 0.65 * progress)
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .accessibilityHidden(true)
    }
}

/// Loading placeholder whose sweep is tinted, so waiting still feels on-brand.
struct BrandSkeleton: View {
    var height: CGFloat = 62
    var cornerRadius: CGFloat = WD.R.row
    var tint: Color = WD.C.violet

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let progress = CGFloat((t / 1.4).truncatingRemainder(dividingBy: 1))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(WD.C.surface)
                .frame(height: height)
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, tint.opacity(0.20), Color.white.opacity(0.05), .clear],
                            startPoint: .leading,
                            endPoint: .trailing,
                        )
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: -geo.size.width * 0.55 + progress * geo.size.width * 1.6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}
