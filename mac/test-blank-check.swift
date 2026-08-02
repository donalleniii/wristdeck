// Verifies the blank-frame detector: a sleeping display photographs as
// near-uniform black and must be rejected, while a real desktop (including a
// dark-mode one, which is dim but has bright spots) must be accepted.
import AppKit

func isEffectivelyBlank(_ rep: NSBitmapImageRep) -> Bool {
    let width = rep.pixelsWide, height = rep.pixelsHigh
    guard width > 0, height > 0 else { return true }
    var total = 0.0, peak = 0.0, samples = 0
    let step = max(1, min(width, height) / 24)
    for x in stride(from: 0, to: width, by: step) {
        for y in stride(from: 0, to: height, by: step) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            total += l; peak = max(peak, l); samples += 1
        }
    }
    guard samples > 0 else { return true }
    return (total / Double(samples)) < 0.035 && peak < 0.15
}

func makeRep(width: Int, height: Int, draw: (NSGraphicsContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var failures = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name)  (blank=\(got), expected \(want))")
}

// A sleeping/locked display: pure black.
let asleep = makeRep(width: 420, height: 260) { _ in
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 420, height: 260).fill()
}
check("sleeping display rejected", isEffectivelyBlank(asleep), true)

// Dark mode desktop: dim overall, but with a bright window and text.
let darkDesktop = makeRep(width: 420, height: 260) { _ in
    NSColor(white: 0.06, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 420, height: 260).fill()
    NSColor(white: 0.92, alpha: 1).setFill()
    NSRect(x: 40, y: 60, width: 220, height: 130).fill() // a window
}
check("dark-mode desktop accepted", isEffectivelyBlank(darkDesktop), false)

// A bright/light desktop.
let bright = makeRep(width: 420, height: 260) { _ in
    NSColor(white: 0.85, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 420, height: 260).fill()
}
check("bright desktop accepted", isEffectivelyBlank(bright), false)

// Nearly-black but with a small lit element (e.g. a single lit window on an
// otherwise black screen) must still count as real content.
let almostDark = makeRep(width: 420, height: 260) { _ in
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 420, height: 260).fill()
    NSColor.white.setFill(); NSRect(x: 150, y: 100, width: 120, height: 70).fill()
}
check("black screen with a lit window accepted", isEffectivelyBlank(almostDark), false)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
