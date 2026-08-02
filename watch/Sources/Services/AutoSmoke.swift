import Foundation
import os

// Headless verification harness, per house convention (-autoDemo/-autoTilt):
// ./build.sh test launches with `-autoSmoke <bridge-url>`, we run the full
// client loop against the stub agent and log each step for `log show` to grep.
enum AutoSmoke {
    private static let log = Logger(subsystem: "com.donalleniii.wristdeck", category: "smoke")

    static var isActive: Bool {
        CommandLine.arguments.contains("-autoSmoke")
    }

    static func runIfRequested() {
        guard isActive else { return }
        let args = CommandLine.arguments
        let url = args.firstIndex(of: "-autoSmoke").flatMap { idx in
            args.indices.contains(idx + 1) ? args[idx + 1] : nil
        } ?? "http://127.0.0.1:8787"
        Speaker.shared.muted = true

        Task {
            log.info("smoke: start against \(url, privacy: .public)")
            let bundleConfig = BundleConfig.load()
            await BridgeClient.shared.configure(candidates: [url], token: bundleConfig.token)

            do {
                let sessions = try await BridgeClient.shared.sessions()
                log.info("smoke: sessions loaded count=\(sessions.count)")

                let result = try await BridgeClient.shared.send(
                    agent: "stub", sessionId: "autosmoke", text: "hello from the watch", summarize: false)
                guard case .started(let turnId) = result else {
                    log.error("smoke: FAIL send busy")
                    return
                }
                log.info("smoke: turn started \(turnId, privacy: .public)")

                var cursor = 0
                var eventTypes: [String] = []
                for _ in 0..<20 {
                    let poll = try await BridgeClient.shared.poll(turnId: turnId, cursor: cursor)
                    eventTypes.append(contentsOf: poll.events.map(\.type))
                    cursor = poll.nextCursor
                    if poll.done { break }
                }
                log.info("smoke: events \(eventTypes.joined(separator: ","), privacy: .public)")
                let ok = eventTypes.contains("done") && eventTypes.contains("text")
                log.info("smoke: \(ok ? "PASS" : "FAIL", privacy: .public)")
            } catch {
                log.error("smoke: FAIL \(String(describing: error), privacy: .public)")
            }
        }
    }
}
