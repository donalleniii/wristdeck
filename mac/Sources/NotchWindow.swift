import AppKit
import SwiftUI

/// A borderless, click-through window pinned under the notch (or top-center on
/// Macs without one). Non-activating so it never steals focus from your work.
final class NotchWindow: NSPanel {
    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true // purely informational; never blocks a click
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centers horizontally on the active screen, tucked just below the menu bar
    /// so it sits directly under the notch on notched displays.
    func reposition() {
        guard let screen = NSScreen.main else { return }
        let size = contentView?.fittingSize ?? frame.size
        let width = max(size.width, 180)
        let height = max(size.height, 34)

        // safeAreaInsets.top is the notch height on notched Macs, 0 elsewhere.
        let notchInset = screen.safeAreaInsets.top
        let topGap: CGFloat = notchInset > 0 ? notchInset + 4 : 8

        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - topGap - height
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
