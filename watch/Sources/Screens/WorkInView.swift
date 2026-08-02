import SwiftUI

/// 02 Work in — interpretation A, recents-first.
/// One hero "continue where you left off" target, three compact recents, then a
/// quiet browse row. Optimizes returning to the thing you were just doing.
struct WorkInView: View {
    let agent: String

    @Environment(AppModel.self) private var model
    @State private var browsingAll = false
    @State private var destination: AppModel.RecentFolder?

    private var title: String { agent == "codex" ? "New Codex" : "New Claude" }

    var body: some View {
        WDScreen {
            if browsingAll {
                allFolders
            } else {
                recentsFirst
            }
        }
        .navigationTitle(title)
        .navigationDestination(item: $destination) { folder in
            SpeakView(agent: agent, folder: folder)
        }
    }

    // MARK: - A: recents-first

    @ViewBuilder
    private var recentsFirst: some View {
        SectionLabel("Pick up where you left off")

        if let last = model.lastUsed {
            heroCard(last)
        } else {
            heroCard(AppModel.RecentFolder(name: "Mac home folder", path: "", when: "default"))
        }

        SectionLabel("Recent").padding(.top, 6)

        // Two recents, not three: the hero card plus three rows plus the browse
        // row overflowed the screen and forced a scroll on the common path.
        ForEach(Array(model.recents.dropFirst().prefix(2))) { folder in
            Button { pick(folder) } label: {
                HStack(spacing: 12) {
                    Text(folder.name)
                        .font(WD.F.row)
                        .foregroundStyle(WD.C.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(folder.when)
                        .font(WD.F.meta)
                        .foregroundStyle(WD.C.textQuaternary)
                }
                .padding(.horizontal, 18)
                .frame(height: WD.M.recentRow)
                .background(
                    RoundedRectangle(cornerRadius: WD.R.recentRow, style: .continuous)
                        .fill(WD.C.surface)
                )
            }
            .pressable()
        }

        Button { withAnimation(WD.Anim.signature) { browsingAll = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                Text("Browse all folders").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(WD.C.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: WD.M.secondaryRow)
            .background(
                RoundedRectangle(cornerRadius: WD.M.secondaryRow / 2, style: .continuous)
                    .fill(WD.C.console)
                    .overlay(
                        RoundedRectangle(cornerRadius: WD.M.secondaryRow / 2, style: .continuous)
                            .strokeBorder(WD.C.hairline(), lineWidth: 1)
                    )
            )
        }
        .pressable()
    }

    private func heroCard(_ folder: AppModel.RecentFolder) -> some View {
        Button { pick(folder) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    StatusDot(color: WD.C.running)
                    Text("Last used · \(folder.when)")
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(1.1)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(folder.name)
                    .font(WD.F.hero)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 6)
                Text(folder.path.isEmpty ? "default" : folder.path)
                    .font(WD.F.mono11)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            // Gradient rather than an overlaid 1pt rule: the rule bleeds past
            // the rounded shape and reads as a stray divider.
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [WD.C.violet.lighten(0.12), WD.C.violet],
                            startPoint: .top,
                            endPoint: .bottom,
                        )
                    )
            )
        }
        .pressable()
    }

    // MARK: - Browse all

    @ViewBuilder
    private var allFolders: some View {
        SectionLabel("All folders")
        ForEach(model.recents) { folder in
            Button { pick(folder) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                        .font(WD.F.rowLarge)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(folder.path)
                        .font(WD.F.mono11)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: WD.R.recentRow, style: .continuous)
                        .fill(WD.C.violet)
                )
            }
            .pressable()
        }
        Button { pick(AppModel.RecentFolder(name: "Mac home folder", path: "", when: "default")) } label: {
            Text("Mac home folder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WD.C.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: WD.M.secondaryRow)
                .background(
                    RoundedRectangle(cornerRadius: WD.M.secondaryRow / 2, style: .continuous)
                        .fill(WD.C.console)
                )
        }
        .pressable()
    }

    private func pick(_ folder: AppModel.RecentFolder) {
        Haptics.click()
        model.folder = folder
        destination = folder
    }
}
