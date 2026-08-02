import AppKit
import Foundation
import os

/// Captures the screen when a watch-driven turn finishes and uploads it, so the
/// watch can show proof of what actually happened.
///
/// This lives in the Mac app rather than the bridge on purpose. macOS grants
/// Screen Recording per binary. The bridge runs under launchd as bare `node`,
/// which macOS silently denies ("could not create image from display"), and
/// granting it would hand a general-purpose interpreter permanent screen access.
/// This is a real app bundle, so macOS prompts normally and the grant is scoped
/// to WristDeckNotch alone.
@MainActor
final class ProofCapture {
    private let log = Logger(subsystem: "com.donalleniii.wristdecknotch", category: "proof")
    private var captured: Set<String> = []
    private var inFlight = false

    /// Called whenever the monitor sees a turn finish.
    func capture(turnId: String, baseURL: URL, token: String) {
        guard !captured.contains(turnId), !inFlight else { return }
        captured.insert(turnId)
        inFlight = true

        Task {
            defer { inFlight = false }
            // Let the auto-opened window finish appearing before photographing it.
            try? await Task.sleep(for: .milliseconds(1400))
            guard let png = await Self.grabScreen() else {
                log.warning("capture failed; Screen Recording permission may be denied")
                return
            }
            await upload(png, turnId: turnId, baseURL: baseURL, token: token)
        }
    }

    /// Shells out to `screencapture`. TCC attributes this to the app bundle, so
    /// the user gets a normal permission prompt the first time.
    ///
    /// Returns nil rather than a black rectangle when there was nothing real to
    /// photograph. That case is the norm, not the exception: this feature exists
    /// for when you are AWAY from the Mac, which is exactly when the display has
    /// gone to sleep and screencapture records pure black.
    private static func grabScreen() async -> Data? {
        wakeDisplay()
        // Give the panel time to actually light up before photographing it.
        try? await Task.sleep(for: .milliseconds(900))

        let path = NSTemporaryDirectory() + "wristdeck-proof.png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x silent, -o no shadow, -C no cursor, -D 1 main display only.
        process.arguments = ["-x", "-o", "-C", "-D", "1", path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let raw = NSImage(contentsOfFile: path) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }

        guard let scaled = downscaleRep(raw, toWidth: 420) else { return nil }
        guard !isEffectivelyBlank(scaled) else { return nil }
        return scaled.representation(using: .png, properties: [:])
    }

    /// Briefly asserts user activity so a sleeping display wakes. Harmless when
    /// the screen is already on.
    private static func wakeDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "3"]
        try? process.run() // fire and forget; it exits on its own
    }

    /// True when the frame carries no real content: an asleep or locked display
    /// photographs as near-uniform black, and shipping that to the watch shows a
    /// blank box that looks broken.
    private static func isEffectivelyBlank(_ rep: NSBitmapImageRep) -> Bool {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return true }

        var total = 0.0
        var peak = 0.0
        var samples = 0
        // Coarse grid sample; reading every pixel is pointless for this decision.
        let step = max(1, min(width, height) / 24)
        for x in stride(from: 0, to: width, by: step) {
            for y in stride(from: 0, to: height, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let luminance = 0.299 * color.redComponent
                    + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
                total += luminance
                peak = max(peak, luminance)
                samples += 1
            }
        }
        guard samples > 0 else { return true }
        let mean = total / Double(samples)
        // Both conditions matter: a dark-mode desktop is dim but has bright
        // spots, whereas a sleeping display is dim everywhere.
        return mean < 0.035 && peak < 0.15
    }

    /// A watch does not need a retina desktop; keep the upload small enough to
    /// travel over LTE.
    private static func downscaleRep(_ image: NSImage, toWidth width: CGFloat) -> NSBitmapImageRep? {
        let sourceSize = image.size
        guard sourceSize.width > 0 else { return nil }
        let scale = width / sourceSize.width
        let target = NSSize(width: width, height: (sourceSize.height * scale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    private func upload(_ png: Data, turnId: String, baseURL: URL, token: String) async {
        guard let url = URL(string: "/turns/\(turnId)/shot", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.httpBody = png
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.info("uploaded proof for \(turnId, privacy: .public) -> HTTP \(code), \(png.count) bytes")
        } catch {
            log.error("upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
