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
    private var hotStrip: NSWindow?
    private var observation: Task<Void, Never>?
    private var collapseTimer: Timer?
    private var visible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpPanel()
        setUpHotStrip()
        monitor.start()

        // Displays come and go; the hot strip has to follow the notch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.setUpHotStrip() }
        }

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

    // MARK: Hover plumbing

    /// One rule: entering (the notch strip or the panel) holds the panel open,
    /// leaving starts a short grace timer so the pointer can cross the gap
    /// between the notch and the panel without the panel vanishing mid-transit.
    private func setHover(_ inside: Bool) {
        collapseTimer?.invalidate()
        collapseTimer = nil
        if inside {
            if !monitor.hoverExpanded {
                monitor.refreshHistory()
                monitor.hoverExpanded = true
                render()
            }
        } else {
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.monitor.hoverExpanded = false
                    self?.render()
                }
            }
        }
    }

    /// Menu fallback for Macs without a notch: opens the panel, and closes it
    /// after 30s unless the pointer ever reaches it (which hands control back
    /// to the normal hover rule).
    @objc fileprivate func showHistoryPanel() {
        monitor.refreshHistory()
        monitor.hoverExpanded = true
        render()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.hoverExpanded = false
                self?.render()
            }
        }
    }

    /// An invisible window over the notch housing itself. Nothing there is
    /// clickable, so intercepting hover in that dead zone blocks nothing,
    /// which is exactly why the working pill can stay click-through while the
    /// notch becomes the "show me history" gesture.
    private func setUpHotStrip() {
        hotStrip?.orderOut(nil)
        hotStrip = nil
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return }
        let inset = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.maxX ?? (screen.frame.midX - 110)
        let right = screen.auxiliaryTopRightArea?.minX ?? (screen.frame.midX + 110)
        guard right > left else { return }
        let rect = NSRect(x: left, y: screen.frame.maxY - inset, width: right - left, height: inset)

        let strip = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        strip.isOpaque = false
        strip.backgroundColor = .clear
        strip.hasShadow = false
        strip.level = .statusBar
        strip.ignoresMouseEvents = false
        strip.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = HotStripView(frame: NSRect(origin: .zero, size: rect.size))
        view.onEnter = { [weak self] in self?.setHover(true) }
        view.onExit = { [weak self] in self?.setHover(false) }
        strip.contentView = view
        strip.orderFrontRegardless()
        hotStrip = strip
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "applewatch",
            accessibilityDescription: "WristDeck activity",
        )
        item.button?.toolTip = "WristDeck"

        // Rebuilt from the ledger every time it opens; see menuNeedsUpdate.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func setUpPanel() {
        let panel = NotchWindow {
            NotchPillHost(
                monitor: self.monitor,
                onHover: { [weak self] inside in
                    // Only the expanded panel maintains itself via hover; the
                    // done pill keeps its plain click behavior, and the working
                    // pill is click-through so it cannot receive hover at all.
                    guard let self, self.monitor.hoverExpanded else { return }
                    self.setHover(inside)
                },
                onShowCatchUp: { [weak self] in
                    // Tapping "While you were away" lands on the history panel
                    // with everything that finished, newest first.
                    self?.monitor.acknowledgeCatchUp()
                    self?.showHistoryPanel()
                },
            )
        }
        panel.alphaValue = 0
        self.panel = panel
    }

    /// Show the pill while the watch is driving something, and keep it up as
    /// "Done" afterwards so a finished turn is noticed rather than missed.
    /// Hover-expansion overrides both: the panel shows whatever you hover from.
    private func render() {
        let working = !monitor.active.isEmpty
        let announcing = monitor.finished != nil
        let expanded = monitor.hoverExpanded
        let catchingUp = monitor.catchUp != nil
        let approving = monitor.firstPendingApproval != nil
        let active = working || announcing || expanded || catchingUp

        let statusSymbol = approving
            ? "exclamationmark.applewatch"
            : (working ? "applewatch.radiowaves.left.and.right" : "applewatch")
        statusItem?.button?.image = NSImage(
            systemSymbolName: statusSymbol,
            accessibilityDescription: "WristDeck activity",
        )

        guard let panel else { return }
        // Click-through while working (purely informational), clickable once
        // there is something to open, catch up on, approve, or interact with.
        panel.ignoresMouseEvents = !(announcing || expanded || catchingUp || approving)

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

// MARK: - History menu

/// The status-item menu doubles as the always-available history list: the last
/// dozen turns straight from the bridge's ledger, each clickable to reopen
/// whatever that turn produced.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh for NEXT open; this open renders the cache, which is already
        // current because the monitor refreshes after every completion.
        monitor.refreshHistory()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(
            title: monitor.bridgeReachable ? "WristDeck" : "WristDeck (bridge offline)",
            action: nil, keyEquivalent: "",
        )
        menu.addItem(header)
        menu.addItem(.separator())

        if monitor.history.isEmpty {
            menu.addItem(NSMenuItem(title: "No finished turns yet", action: nil, keyEquivalent: ""))
        }
        for entry in monitor.history.prefix(12) {
            menu.addItem(historyItem(for: entry))
        }

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show History Panel", action: #selector(showHistoryPanel), keyEquivalent: "h")
        show.target = self
        menu.addItem(show)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func historyItem(for entry: HistoryEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.truncate(entry.headline, to: 56),
            action: entry.hasTarget ? #selector(openHistoryItem(_:)) : nil,
            keyEquivalent: "",
        )
        item.target = entry.hasTarget ? self : nil
        item.representedObject = entry.turnId

        let symbol = entry.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let tint: NSColor = entry.failed
            ? NSColor(red: 1.0, green: 0.28, blue: 0.28, alpha: 1)
            : NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.failed ? "failed" : "done")?
            .withSymbolConfiguration(.init(paletteColors: [tint]))

        if #available(macOS 14.4, *) {
            item.subtitle = "\(entry.agentLabel) · \(Self.timeAgo(entry.finishedDate)) · \(Self.durationText(entry.durationMs))"
        }
        var tip = entry.prompt.isEmpty ? "" : "\u{201C}\(entry.prompt)\u{201D}"
        if !entry.cwd.isEmpty { tip += (tip.isEmpty ? "" : "\n") + entry.cwd }
        item.toolTip = tip.isEmpty ? nil : tip
        return item
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        guard let turnId = sender.representedObject as? String else { return }
        monitor.openTurn(turnId)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }

    private static func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func durationText(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// Bridges the observable monitor into the panel's SwiftUI content.
struct NotchPillHost: View {
    var monitor: ActivityMonitor
    var onHover: (Bool) -> Void = { _ in }
    var onShowCatchUp: () -> Void = {}

    var body: some View {
        Group {
            // Hover expansion beats everything; then a parked approval (the
            // only state where an agent is BLOCKED on the human); then live
            // work; then "Done"; then catch-up.
            if monitor.hoverExpanded {
                HistoryPanelView(monitor: monitor)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let waiting = monitor.firstPendingApproval {
                NotchApprovalPillView(
                    agentLabel: monitor.active.first(where: { $0.turnId == waiting.turnId })?.agentLabel ?? "Agent",
                    approval: waiting.approval,
                    onAllow: { monitor.decide(turnId: waiting.turnId, approvalId: waiting.approval.approvalId, allow: true) },
                    onDeny: { monitor.decide(turnId: waiting.turnId, approvalId: waiting.approval.approvalId, allow: false) },
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let first = monitor.active.first {
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
            } else if let catchUp = monitor.catchUp {
                NotchCatchUpPillView(
                    count: catchUp.count,
                    onShow: { onShowCatchUp() },
                    onDismiss: { monitor.acknowledgeCatchUp() },
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onHover(perform: onHover)
        .animation(.spring(response: 0.34, dampingFraction: 0.76), value: monitor.active)
        .animation(.spring(response: 0.34, dampingFraction: 0.76), value: monitor.finished)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: monitor.hoverExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.76), value: monitor.catchUp)
        .animation(.spring(response: 0.34, dampingFraction: 0.76), value: monitor.firstPendingApproval?.approval.approvalId)
        .fixedSize()
    }
}

/// Mouse-enter/exit reporter for the invisible notch strip.
final class HotStripView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
