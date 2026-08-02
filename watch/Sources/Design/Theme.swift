import SwiftUI
import UIKit

// Design tokens from the WristDeck handoff. Values are in the watch's own point
// space (410 x 502 pt, Ultra 49mm), so they map 1:1 with the spec numbers.
enum WD {
    // MARK: - Color

    enum C {
        static let bg = Color.black
        static let surface = Color(hex: 0x1C1C1E)
        static let surfaceHover = Color(hex: 0x2C2C2E)
        static let console = Color(hex: 0x141414)

        /// Primary action violet, carried over from the current app.
        static let violet = Color(hex: 0x6A63A6)
        static let violetHover = Color(hex: 0x7A73B8)

        static let claude = Color(hex: 0xF97316)
        static let codex = Color(hex: 0x38BDF8)
        static let running = Color(hex: 0x30D158)
        static let queued = Color(hex: 0xFFD60A)
        static let alert = Color(hex: 0xFF4747)
        static let alertSurface = Color(hex: 0x1C1414)
        static let alertSurfaceRaised = Color(hex: 0x2C1414)

        static let textPrimary = Color.white
        static let textSecondary = Color(hex: 0xC7C7CC)
        static let textTertiary = Color(hex: 0x8E8E93)
        static let textQuaternary = Color(hex: 0x636366)
        static let textDisabled = Color(hex: 0x48484A)

        static let bodyMuted = Color(hex: 0xA8A29E)

        static func hairline(_ opacity: Double = 0.09) -> Color {
            Color.white.opacity(opacity)
        }

        static func agent(_ agent: String) -> Color {
            agent == "codex" ? codex : claude
        }

        /// Text that sits on top of an agent-colored fill.
        static func onAgent(_ agent: String) -> Color {
            agent == "codex" ? Color(hex: 0x0C1620) : Color(hex: 0x1C1917)
        }
    }

    // MARK: - Type
    // System (SF) for all UI. Space Mono is not on watchOS, so paths and console
    // output use the system monospaced face at the same sizes.

    enum F {
        static let hero = Font.system(size: 24, weight: .bold)
        static let speak = Font.system(size: 22, weight: .bold)
        static let pillLabel = Font.system(size: 19, weight: .semibold)
        static let headerTitle = Font.system(size: 19, weight: .bold)
        static let transcript = Font.system(size: 19, weight: .medium)
        static let rowLarge = Font.system(size: 18, weight: .bold)
        static let row = Font.system(size: 17, weight: .semibold)
        static let clock = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 16, weight: .semibold)
        static let statusLabel = Font.system(size: 15, weight: .bold)
        static let elapsed = Font.system(size: 14, weight: .semibold)
        static let sectionLabel = Font.system(size: 13, weight: .bold)
        static let meta = Font.system(size: 12, weight: .semibold)
        static let micro = Font.system(size: 11, weight: .bold)

        static let mono13 = Font.system(size: 13, design: .monospaced)
        static let mono12 = Font.system(size: 12, design: .monospaced)
        static let mono11 = Font.system(size: 11, design: .monospaced)
    }

    // MARK: - Radius

    enum R {
        static let primaryPill: CGFloat = 29
        static let speakPill: CGFloat = 32
        static let sendPill: CGFloat = 28
        static let card: CGFloat = 24
        static let row: CGFloat = 22
        static let recentRow: CGFloat = 26
        static let chip: CGFloat = 19
        static let notification: CGFloat = 26
    }

    // MARK: - Metrics

    enum M {
        static let edge: CGFloat = 16
        static let bottomSafe: CGFloat = 34
        static let headerMin: CGFloat = 44
        static let primaryPillHeight: CGFloat = 58
        static let speakPillHeight: CGFloat = 64
        static let sendPillHeight: CGFloat = 56
        static let secondaryRow: CGFloat = 50
        static let recentRow: CGFloat = 52
        static let actionPill: CGFloat = 56
        static let controlRow: CGFloat = 54
        static let chip: CGFloat = 38
        static let rowGap: CGFloat = 12
        static let tightGap: CGFloat = 10
    }

    // MARK: - Motion

    enum Anim {
        /// The brand's signature ease: cubic-bezier(0.16, 1, 0.3, 1). No bounce.
        static let signature = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.28)
        static let notificationDrop = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)
        static let statusPulse = Animation.easeInOut(duration: 2).repeatForever(autoreverses: true)
        static let sessionPulse = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Mixes toward white. Used for the pills' inset top highlight, which the
    /// spec draws as a 1pt rule but which reads cleaner as a gradient at these
    /// corner radii.
    func lighten(_ amount: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(
            .sRGB,
            red: Double(r + (1 - r) * t),
            green: Double(g + (1 - g) * t),
            blue: Double(b + (1 - b) * t),
            opacity: Double(a)
        )
    }
}

/// Screen entrance: opacity 0->1 plus a 10pt rise, on the signature ease.
struct ScreenEntrance: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(WD.Anim.signature) { shown = true }
            }
    }
}

extension View {
    func screenEntrance() -> some View { modifier(ScreenEntrance()) }
}
