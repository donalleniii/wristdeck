import SwiftUI

/// Proof of work: a thumbnail of the Mac's screen at the moment a turn
/// finished. Answers "did that actually happen?" without walking to the desk.
struct ProofShot: View {
    let turnId: String
    var caption: String?

    @State private var image: UIImage?
    @State private var state: LoadState = .loading

    private enum LoadState { case loading, ready, missing }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .loading:
                BrandSkeleton(height: 92, cornerRadius: WD.R.row)
                    .transition(.opacity)
            case .ready:
                if let image {
                    NavigationLink {
                        ProofFullScreen(turnId: turnId, caption: caption)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: WD.R.row, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: WD.R.row, style: .continuous)
                                    .strokeBorder(WD.C.hairline(0.12), lineWidth: 1)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(.black.opacity(0.55)))
                                    .padding(6)
                            }
                    }
                    .pressable()
                    .springEntrance()
                }
            case .missing:
                EmptyView()
            }

            if state == .ready, let caption {
                Text(caption)
                    .font(WD.F.meta)
                    .foregroundStyle(WD.C.textQuaternary)
                    .lineLimit(1)
            }
        }
        .task(id: turnId) { await load() }
    }

    private func load() async {
        state = .loading
        // The Mac captures a beat after the turn ends, so a first miss is normal.
        for attempt in 0..<4 {
            if let data = await BridgeClient.shared.proofShot(turnId: turnId),
               data.count > 1024,
               let decoded = UIImage(data: data) {
                image = decoded
                state = .ready
                return
            }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 3))
        }
        // Show nothing rather than an empty frame. A missing screenshot usually
        // means the Mac's display was asleep, which is not worth a broken-looking
        // placeholder on the wrist.
        image = nil
        state = .missing
    }
}
