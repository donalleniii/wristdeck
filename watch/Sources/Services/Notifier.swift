import Foundation
import UserNotifications
import WatchKit
import os

/// Taps you on the wrist when an agent is waiting on a decision.
///
/// Deliberately LOCAL notifications driven by background refresh, not APNs:
/// APNs would need an Auth Key generated in the Apple Developer portal, the push
/// capability on the App ID, and a token round-trip. Local + background refresh
/// needs none of that and works today. The tradeoff is latency (watchOS decides
/// when to grant background time, typically every 15-30 min, more often when the
/// app has a complication on the active face, which WristDeck does), which is
/// why the bridge's approval window was widened to 10 minutes.
@MainActor
final class Notifier {
    static let shared = Notifier()

    private let log = Logger(subsystem: "com.donalleniii.wristdeck", category: "notify")
    private var announced: Set<String> = []
    private var authorized = false

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.authorized = granted
                if let error {
                    self?.log.error("auth failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self?.log.info("notification auth granted=\(granted)")
                }
            }
        }
    }

    /// Fires once per approval. Safe to call on every poll.
    func announce(_ alerts: [AppModel.Alert]) {
        guard authorized else { return }
        for alert in alerts where alert.approval != nil && !announced.contains(alert.id) {
            announced.insert(alert.id)
            post(title: alert.title, body: alert.body, id: alert.id)
        }
        // Forget anything no longer pending, so a later identical ask still fires.
        let live = Set(alerts.map(\.id))
        announced.formIntersection(live)
    }

    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive // approvals expire; earn the interrupt

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil, // deliver now
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.log.error("post failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        WKInterfaceDevice.current().play(.notification)
        log.info("announced approval \(id, privacy: .public)")
    }

    /// Clears a notification once the thing it was about is resolved.
    func withdraw(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        announced.remove(id)
    }
}
