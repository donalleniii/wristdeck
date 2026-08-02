import SwiftUI

/// Full-screen proof viewer. Behaves like the watch's own Photos app: the crown
/// zooms, a drag pans, and the zoom level PERSISTS until you wind it back, so
/// you can settle on a region and study it rather than fighting a spring-back.
struct ProofFullScreen: View {
    let turnId: String
    let caption: String?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: Double = 1
    @State private var committedOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var showChrome = true

    private let minZoom: Double = 1
    private let maxZoom: Double = 6

    private var offset: CGSize {
        CGSize(width: committedOffset.width + dragOffset.width,
               height: committedOffset.height + dragOffset.height)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard zoom > 1 else { return }
                                    dragOffset = value.translation
                                }
                                .onEnded { _ in
                                    committedOffset = clamp(offset, in: geo.size)
                                    dragOffset = .zero
                                }
                        )
                        .onTapGesture {
                            withAnimation(.wdSnap) { showChrome.toggle() }
                        }
                } else {
                    ProgressView()
                }

                if showChrome {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            if zoom > 1.02 {
                                Button {
                                    withAnimation(.wdSettle) {
                                        zoom = 1
                                        committedOffset = .zero
                                    }
                                } label: {
                                    Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .pressable()
                            }
                            Text(zoom > 1.02 ? String(format: "%.1fx", zoom) : (caption ?? "Crown to zoom"))
                                .font(.system(size: 11))
                                .foregroundStyle(WD.C.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .padding(.bottom, 4)
                    }
                    .transition(.opacity)
                }
            }
            // The crown is the watch's native zoom control, and unlike a pinch it
            // holds wherever you leave it.
            .focusable()
            .digitalCrownRotation(
                $zoom,
                from: minZoom,
                through: maxZoom,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true,
            )
            .onChange(of: zoom) {
                // Winding back to 1x recentres, so you never end up zoomed out
                // AND panned off into empty space.
                if zoom <= 1.02 {
                    committedOffset = .zero
                } else {
                    committedOffset = clamp(committedOffset, in: geo.size)
                }
            }
        }
        .navigationTitle("Proof")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Keeps the panned image from being dragged entirely off screen.
    private func clamp(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let slackX = max(0, (size.width * zoom - size.width) / 2)
        let slackY = max(0, (size.height * zoom - size.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY),
        )
    }

    private func load() async {
        for attempt in 0..<3 {
            if let data = await BridgeClient.shared.proofShot(turnId: turnId),
               data.count > 1024,
               let decoded = UIImage(data: data) {
                image = decoded
                return
            }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
        }
    }
}
