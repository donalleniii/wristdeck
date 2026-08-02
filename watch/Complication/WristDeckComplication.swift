import SwiftUI
import WidgetKit

// Watch-face complication whose job is simply to launch WristDeck in one tap.
// Tapping any WidgetKit accessory widget opens its host app, so no deep link is
// needed. Kept static (a single timeline entry, never reloaded) because there is
// nothing live to show yet; when the approval gate lands, this is where a
// "1 waiting" badge would go, fed through an App Group.
struct WristDeckEntry: TimelineEntry {
    let date: Date
}

struct WristDeckProvider: TimelineProvider {
    func placeholder(in context: Context) -> WristDeckEntry {
        WristDeckEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (WristDeckEntry) -> Void) {
        completion(WristDeckEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WristDeckEntry>) -> Void) {
        completion(Timeline(entries: [WristDeckEntry(date: .now)], policy: .never))
    }
}

/// The mark: a terminal chevron plus a voice bar, matching the app icon.
struct WristDeckMark: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = max(1.6, side * 0.11)
            HStack(spacing: side * 0.1) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: side * 0.22, y: side * 0.22))
                    path.addLine(to: CGPoint(x: 0, y: side * 0.44))
                }
                .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .frame(width: side * 0.22, height: side * 0.44)

                Capsule()
                    .frame(width: line, height: side * 0.44)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct WristDeckComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WristDeckEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                WristDeckMark()
                    .padding(9)
            }
        case .accessoryCorner:
            WristDeckMark()
                .padding(4)
                .widgetLabel("WristDeck")
        case .accessoryInline:
            Label("WristDeck", systemImage: "chevron.left.forwardslash.chevron.right")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                WristDeckMark()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WristDeck")
                        .font(.headline)
                    Text("Claude and Codex")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        default:
            WristDeckMark()
        }
    }
}

@main
struct WristDeckComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.donalleniii.wristdeck.complication", provider: WristDeckProvider()) { entry in
            WristDeckComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("WristDeck")
        .description("Open WristDeck to talk to Claude or Codex.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular,
        ])
    }
}
