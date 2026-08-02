import SwiftUI
import WatchKit

enum AppSetup {
    /// Overrides from Settings win; otherwise the bundled Config.plist.
    static func configureClient() async {
        await BridgeClient.shared.reconfigure()
    }
}

@main
struct WristDeckApp: App {
    @WKApplicationDelegateAdaptor(BackgroundRefresh.self) private var delegate
    @State private var model = AppModel.shared

    /// `-autoAsk` opens straight into a stub conversation that parks on an
    /// approval, so the card can be verified headlessly.
    private var autoAsk: Bool { CommandLine.arguments.contains("-autoAsk") }

    var body: some Scene {
        WindowGroup {
            RootView(autoAsk: autoAsk)
                .environment(model)
                .tint(WD.C.violet)
                .onAppear {
                    WKExtension.shared().isFrontmostTimeoutExtended = true
                    AutoSmoke.runIfRequested()
                }
                .task {
                    if !AutoSmoke.isActive {
                        await AppSetup.configureClient()
                        model.start()
                    }
                }
        }
    }
}

/// Hosts the navigation stack plus the notification overlay that can land on
/// top of any screen.
struct RootView: View {
    let autoAsk: Bool

    @Environment(AppModel.self) private var model
    @State private var dismissedAlertIds: Set<String> = []
    @State private var showAlerts = false

    private var liveAlert: AppModel.Alert? {
        model.alerts.first { !dismissedAlertIds.contains($0.id) }
    }

    /// `-screen <name>` jumps straight to one screen, so every screen can be
    /// verified headlessly the way `-autoDemo` does elsewhere in this project.
    private var forcedScreen: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screen"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    var body: some View {
        NavigationStack {
            if autoAsk {
                ConversationView(agent: "stub", newWithCwd: "/tmp/demo", autoSend: "ask")
            } else if let forcedScreen {
                forced(forcedScreen)
            } else {
                HomeView()
                    .navigationDestination(isPresented: $showAlerts) { AlertsView() }
            }
        }
        // No in-app banner for approvals. Home and Alerts both render the live
        // decision card now, and the banner literally covered the Yes/No buttons
        // it was pointing at. Being told while the app is CLOSED is the real
        // need, and that is what the local notification does.
    }

    @ViewBuilder
    private func forced(_ name: String) -> some View {
        let demoFolder = AppModel.RecentFolder(
            name: "bridge", path: "~/Projects/WristDeck/bridge", when: "12m ago")
        switch name {
        case "workin": WorkInView(agent: "claude")
        case "speak": SpeakView(agent: "claude", folder: demoFolder)
        case "session": SessionView(sessionId: "", agent: "claude", title: "Claude")
        case "projects": ProjectsView()
        case "actions": QuickActionsView()
        case "alerts": AlertsView()
        default: HomeView()
        }
    }
}
