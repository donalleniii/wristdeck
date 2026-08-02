import SwiftUI

// Polish layer. The handoff specifies "no bounce, no elastic"; Don asked for
// springier, more alive motion after using the app, so these deliberately
// override that. Kept subtle on purpose: on a 49mm face, big movement reads as
// a toy, and every animating pixel costs battery.

extension Animation {
    /// Default for taps and state flips. Fast, tiny overshoot.
    static let wdSnap = Animation.spring(response: 0.3, dampingFraction: 0.68)
    /// For things entering the screen.
    static let wdEnter = Animation.spring(response: 0.42, dampingFraction: 0.75)
    /// For things that must feel weighty (approval cards, kill confirm).
    static let wdSettle = Animation.spring(response: 0.5, dampingFraction: 0.7)
}

/// Presses scale down and spring back, so every tap feels physical.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.955

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.wdSnap, value: configuration.isPressed)
    }
}

extension View {
    /// Replaces `.pressable()` where a press should feel physical.
    func pressable(scale: CGFloat = 0.955) -> some View {
        buttonStyle(PressableStyle(scale: scale))
    }
}

/// Three dots breathing in sequence. Used wherever an agent is thinking.
struct ThinkingDots: View {
    var color: Color = WD.C.textTertiary
    var size: CGFloat = 6

    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(scale(for: index))
                    .opacity(opacity(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func scale(for index: Int) -> CGFloat {
        let offset = Double(index) * 0.22
        let local = min(max(phase - offset, 0), 1)
        return 0.6 + 0.4 * local
    }

    private func opacity(for index: Int) -> Double {
        let offset = Double(index) * 0.22
        let local = min(max(phase - offset, 0), 1)
        return 0.35 + 0.65 * local
    }
}

/// A slim arc that sweeps around, for "working" states that need more presence
/// than dots (the Session status bar while a turn runs).
struct WorkingRing: View {
    var color: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Skeleton row that shimmers while real content loads, instead of a spinner.
struct SkeletonRow: View {
    var height: CGFloat = 58
    var cornerRadius: CGFloat = WD.R.row

    @State private var sweep = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(WD.C.surface)
            .frame(height: height)
            .overlay(
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.06), .clear],
                    startPoint: .leading,
                    endPoint: .trailing,
                )
                .frame(width: 120)
                .offset(x: sweep ? 260 : -180)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
    }
}

/// A cursor that actually blinks on a 1s step, per the console spec.
struct BlinkingCursor: View {
    var color: Color = WD.C.running

    @State private var on = true
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("█")
            .foregroundStyle(color)
            .opacity(on ? 1 : 0)
            .onReceive(tick) { _ in on.toggle() }
    }
}

/// Springy entrance used by screens: fade, rise, and a whisper of scale.
struct SpringEntrance: ViewModifier {
    var delay: Double = 0

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .scaleEffect(shown ? 1 : 0.985, anchor: .top)
            .onAppear {
                withAnimation(.wdEnter.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func springEntrance(delay: Double = 0) -> some View {
        modifier(SpringEntrance(delay: delay))
    }

    /// Staggers a list so rows arrive in sequence rather than all at once.
    func staggered(_ index: Int, step: Double = 0.035, cap: Int = 8) -> some View {
        modifier(SpringEntrance(delay: Double(min(index, cap)) * step))
    }
}
