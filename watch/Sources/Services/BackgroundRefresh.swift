import Foundation
import WatchKit
import os

/// Wakes the app periodically so a pending approval can tap you on the wrist
/// even when you are not looking at WristDeck.
///
/// watchOS grants this budget at its own discretion. Apps with a complication on
/// the ACTIVE watch face get it far more often, which is a concrete reason to
/// keep the WristDeck complication on your face if you care about being told.
@MainActor
final class BackgroundRefresh: NSObject, WKApplicationDelegate {
    private let log = Logger(subsystem: "com.donalleniii.wristdeck", category: "bgrefresh")
    private let model = AppModel.shared

    func applicationDidFinishLaunching() {
        // The headless harnesses (-screen, -autoAsk) must not sit on a
        // permission alert, which would block every screenshot.
        let harness = CommandLine.arguments.contains("-screen")
            || CommandLine.arguments.contains("-autoAsk")
            || CommandLine.arguments.contains("-autoSmoke")
        if !harness { Notifier.shared.requestAuthorization() }
        schedule(in: 60) // first check soon after launch
    }

    func applicationDidEnterBackground() {
        // Re-arm on the way out; without this the chain stops after one wake.
        schedule(in: 15 * 60)
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refresh = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            log.info("background wake")
            Task { @MainActor in
                await model.checkForApprovals()
                schedule(in: 15 * 60)
                refresh.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func schedule(in seconds: TimeInterval) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(seconds),
            userInfo: nil,
        ) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.log.error("schedule failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
