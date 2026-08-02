// Generates the app icon: terminal chevron + voice waveform on a deep gradient.
// watchOS masks icons to a circle, so all art stays in the circle-safe region.
// usage: swift tools/make_icon.swift Assets.xcassets/AppIcon.appiconset/AppIcon1024.png
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count > 1 else {
    print("usage: make_icon.swift <output.png>")
    exit(1)
}

// Draw into an explicit 1024px bitmap; NSImage.lockFocus on a Retina Mac
// would render at 2x and actool rejects a 2048px icon.
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.32, blue: 0.40, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)

NSColor.white.setStroke()

let chevron = NSBezierPath()
chevron.lineWidth = 58
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: 310, y: 646))
chevron.line(to: NSPoint(x: 442, y: 512))
chevron.line(to: NSPoint(x: 310, y: 378))
chevron.stroke()

let bars: [(CGFloat, CGFloat)] = [(556, 118), (642, 214), (728, 148)]
for (x, halfHeight) in bars {
    let bar = NSBezierPath()
    bar.lineWidth = 58
    bar.lineCapStyle = .round
    bar.move(to: NSPoint(x: x, y: 512 - halfHeight))
    bar.line(to: NSPoint(x: x, y: 512 + halfHeight))
    bar.stroke()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("failed to render icon")
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
