import SwiftUI

/// Shown when an agent wants to do something public, irreversible, or costly.
/// Deliberately loud and specific: the whole point is that you can tell what
/// you are agreeing to, including WHICH folder, before it happens.
struct ApprovalCard: View {
    let approval: PendingApproval
    let queuePosition: Int
    let queueTotal: Int
    let busy: Bool
    let onDecision: (Bool) -> Void

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Approve?")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if queueTotal > 1 {
                    Text("\(queuePosition)/\(queueTotal)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.orange)

            Text(approval.summary)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            // Verbatim, never normalized: the string shown must be the string
            // that runs.
            Text(approval.detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !approval.folderName.isEmpty {
                Label(approval.folderName, systemImage: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let cost = approval.costHint {
                Label(cost, systemImage: "creditcard")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Button {
                    onDecision(false)
                } label: {
                    Text("No")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)

                Button {
                    onDecision(true)
                } label: {
                    Text("Yes")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy)

            Text(busy ? "Sending..." : "Expires in \(approval.secondsRemaining(now: now))s")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.orange.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                )
        )
        .springEntrance()
        .onReceive(tick) { now = $0 }
    }
}
