import SwiftUI

/// Lands on top of whatever screen is showing when something needs you.
/// Driven by real pending approvals rather than the prototype's timer.
struct NotificationOverlay: View {
    let title: String
    /// Not named `body`: that collides with View's own requirement.
    let message: String
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(WD.C.alert)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 13))
                        .foregroundStyle(WD.C.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .pressable()
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xE5C9C9))
                .lineLimit(2)
                .padding(.leading, 25)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: WD.R.notification, style: .continuous)
                .fill(WD.C.alertSurfaceRaised.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: WD.R.notification, style: .continuous)
                        .strokeBorder(WD.C.alert.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.7), radius: 12, y: 6)
        )
        .padding(.horizontal, 12)
        .offset(y: shown ? 0 : -40)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(WD.Anim.notificationDrop) { shown = true }
            Haptics.failure()
        }
        .onTapGesture(perform: onOpen)
    }
}
