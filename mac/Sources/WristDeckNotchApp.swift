import AppKit
import SwiftUI

@main
struct WristDeckNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows: this is a menu-bar agent plus a floating pill.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = ActivityMonitor()
    private var statusItem: NSStatusItem?
    private var panel: NotchWindow?
    private var observation: Task<Void, Never>?
    private var visible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpPanel()
        monitor.start()

        // Cheap poll of the observable rather than wiring withObservationTracking
        // recursion; the monitor already updates at ~1Hz.
        observation = Task { [weak self] in
            while !Task.isCancelled {
                self?.render()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observation?.cancel()
        monitor.stop()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "applewatch",
            accessibilityDescription: "WristDeck activity",
        )
        item.button?.toolTip = "WristDeck"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "WristDeck Notch", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func setUpPanel() {
        let panel = NotchWindow {
            NotchPillHost(monitor: self.monitor)
        }
        panel.alphaValue = 0
        self.panel = panel
    }

    /// Show the pill while the watch is driving something, and keep it up as
    /// "Done" afterwards so a finished turn is noticed rather than missed.
    private func render() {
        let working = !monitor.active.isEmpty
        let announcing = monitor.finished != nil
        let active = working || announcing

        statusItem?.button?.image = NSImage(
            systemSymbolName: working ? "applewatch.radiowaves.left.and.right" : "applewatch",
            accessibilityDescription: "WristDeck activity",
        )

        guard let panel else { return }
        // Click-through while working (purely informational), clickable once
        // there is something to open.
        panel.ignoresMouseEvents = !announcing

        if active {
            panel.reposition()
            if !visible {
                visible = true
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.reposition()
            }
        } else if visible {
            visible = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
    }
}

/// Bridges the observable monitor into the panel's SwiftUI content.
struct NotchPillHost: View {
    var monitor: ActivityMonitor

    var body: some View {
        Group {
            // Live work wins the pill; a finished turn takes it over once idle.
            if let first = monitor.active.first {
                NotchPillView(
                    item: first,
                    elapsed: monitor.elapsed,
                    extraCount: max(0, monitor.active.count - 1),
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let done = monitor.finished {
                NotchDonePillView(
                    item: done,
                    onOpen: { monitor.openFinished() },
                    onDismiss: { monitor.acknowledgeFinished() },
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.76), value: monitor.active)
        .animation(.spring(response: 0.34, dampingFraction: 0.76), value: monitor.finished)
        .fixedSize()
    }
}
