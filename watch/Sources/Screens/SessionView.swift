import SwiftUI

/// 04 Session — live output, pause, kill, reply.
/// Wraps the existing ConversationModel (polling, approvals, TTS) in the
/// handoff's console presentation. Output appends by token as it arrives rather
/// than the prototype's per-character fake.
struct SessionView: View {
    let sessionId: String
    let agent: String
    let title: String
    var attachTurnId: String?
    var openingPrompt: String?

    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ioMode") private var ioModeRaw = IOMode.voiceVoice.rawValue
    @AppStorage("speechRate") private var speechRate = Constants.defaultSpeechRate

    @State private var model: ConversationModel
    @State private var confirmKill = false
    @State private var elapsed = 0
    @State private var cursorOn = true

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(sessionId: String, agent: String, title: String, attachTurnId: String? = nil, openingPrompt: String? = nil) {
        self.sessionId = sessionId
        self.agent = agent
        self.title = title
        self.attachTurnId = attachTurnId
        self.openingPrompt = openingPrompt
        _model = State(initialValue: ConversationModel(
            agent: agent,
            sessionId: sessionId.isEmpty ? nil : sessionId,
        ))
    }

    private var ioMode: IOMode { IOMode(rawValue: ioModeRaw) ?? .voiceVoice }

    private var statusColor: Color {
        if model.running { return WD.C.running }
        return model.entries.contains { $0.role == .error } ? WD.C.textTertiary : WD.C.textTertiary
    }

    private var statusLabel: String {
        model.running ? "Running" : (model.entries.contains { $0.role == .error } ? "Stopped" : "Done")
    }

    /// Page one is a GLANCE: an animated icon and two or three words about what
    /// is happening right now. Page two holds the prompt and full output.
    ///
    /// The previous version led with the raw console. On a real wrist that
    /// crammed the status row so hard "Running" rendered one letter per line,
    /// and it showed the thing you least need at the moment work starts: your
    /// own prompt, truncated mid-word.
    var body: some View {
        TabView {
            glancePane.tag(0)
            detailPane.tag(1)
        }
        .tabViewStyle(.verticalPage)
        .background(WD.C.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { _ in
            if model.running { elapsed += 1 }
            cursorOn.toggle()
        }
        .animation(.wdSettle, value: model.pending)
        .animation(.wdSnap, value: model.running)
        .animation(.wdSettle, value: confirmKill)
        .onChange(of: scenePhase) { if scenePhase == .active { model.resumeIfNeeded() } }
        .onDisappear {
            model.stopPolling()
            Speaker.shared.stop()
        }
        .task {
            if let attachTurnId, let openingPrompt {
                model.attach(turnId: attachTurnId, prompt: openingPrompt, ioMode: ioMode, speechRate: speechRate)
            }
        }
    }

    // MARK: - Page one: the glance

    private var glancePane: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 24) // clears the back chevron and clock

            // Anything waiting on a decision outranks everything else.
            if let approval = model.pending.first {
                ScrollView {
                    ApprovalCard(
                        approval: approval,
                        queuePosition: 1,
                        queueTotal: model.pending.count,
                        busy: model.respondingTo != nil,
                    ) { allow in
                        model.respond(to: approval, allow: allow)
                    }
                    .padding(.horizontal, WD.M.edge)
                }
            } else if confirmKill {
                killConfirm.padding(.horizontal, WD.M.edge)
            } else {
                ZStack {
                    if model.running {
                        AgentOrb(color: WD.C.agent(agent), mode: .working, diameter: 108)
                    } else {
                        AgentOrb(color: WD.C.agent(agent), mode: .idle, diameter: 100)
                        Image(systemName: doneIcon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                }
                .frame(maxHeight: .infinity)

                // Two or three words on what is happening, nothing more.
                Text(glanceLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
                    .animation(.wdSnap, value: glanceLine)

                Text(subLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WD.C.textQuaternary)
                    .lineLimit(1)

                actionRow.padding(.horizontal, WD.M.edge)
            }

            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .springEntrance()
    }

    private var doneIcon: String {
        model.entries.contains { $0.role == .error } ? "exclamationmark.triangle.fill" : "checkmark"
    }

    /// What it is doing right now, in as few words as possible.
    private var glanceLine: String {
        if model.running {
            return model.statusLabel.isEmpty ? "Working…" : model.statusLabel
        }
        // Finished: lead with the spoken summary if we have one, since that is
        // already written to be short.
        if let summary = model.summaryText, !summary.isEmpty { return summary }
        if let last = model.entries.last(where: { $0.role == .agent }), !last.text.isEmpty {
            return String(last.text.prefix(90))
        }
        return statusLabel
    }

    private var subLine: String {
        let time = "\(elapsed / 60)m \(elapsed % 60)s"
        let modelPart = model.modelName.isEmpty ? "" : " · \(shortModel(model.modelName))"
        // While running the headline is the ACTION, so naming the state here
        // adds something. Once finished the headline already says how it went,
        // and repeating "Done · Done" just looks broken.
        return model.running ? "\(statusLabel) · \(time)\(modelPart)" : "\(time)\(modelPart)"
    }

    /// One row, never crowded: stop while running, reply once finished.
    @ViewBuilder
    private var actionRow: some View {
        if model.running {
            Button {
                Haptics.failure()
                withAnimation(.wdSettle) { confirmKill = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text("Stop").font(WD.F.body)
                }
                .foregroundStyle(WD.C.alert)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Capsule().fill(WD.C.surface)
                )
            }
            .pressable()
        } else {
            NavigationLink {
                SpeakView(
                    agent: agent,
                    folder: appModel.folder ?? AppModel.RecentFolder(name: "Mac home folder", path: "", when: ""),
                    continuingSessionId: model.sessionId,
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                    Text("Reply").font(WD.F.body)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(WD.C.violet))
            }
            .pressable()
        }
    }

    // MARK: - Page two: the detail

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Prompt")
                Text(promptText)
                    .font(.system(size: 13))
                    .foregroundStyle(WD.C.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: WD.R.row, style: .continuous)
                            .fill(WD.C.surface)
                    )

                SectionLabel("Output")
                console
            }
            .padding(.horizontal, WD.M.edge)
            .padding(.top, 26)
            .padding(.bottom, WD.M.bottomSafe)
        }
    }

    private var promptText: String {
        model.entries.first(where: { $0.role == .user })?.text ?? openingPrompt ?? "—"
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.running {
                WorkingRing(color: statusColor, size: 13)
            } else {
                StatusDot(color: statusColor, size: 9)
            }
            Text(statusLabel)
                .font(WD.F.statusLabel)
                .foregroundStyle(statusColor)
                .contentTransition(.opacity)
            if model.running {
                WaveDots(color: WD.C.agent(agent), count: 4, dot: 3.5, amplitude: 2.5)
            }
            Spacer()
            if !model.modelName.isEmpty {
                Text(shortModel(model.modelName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WD.C.agent(agent))
                    .lineLimit(1)
            }
            Text("\(elapsed / 60)m \(elapsed % 60)s")
                .font(WD.F.elapsed)
                .monospacedDigit()
                .foregroundStyle(WD.C.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(WD.C.surface)
        )
    }

    private var console: some View {
        // Text concatenation keeps the cursor on the same line as the last
        // character, which an HStack would not.
        VStack(alignment: .leading, spacing: 0) {
            // Rebuilding the string is what makes the cursor actually blink;
            // animating opacity would fade the whole console with it.
            (
                Text(consoleText).foregroundColor(WD.C.textSecondary)
                    + Text(model.running && cursorOn ? " █" : "").foregroundColor(WD.C.running)
            )
            .font(WD.F.mono13)
            .lineSpacing(13 * 0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: consoleText)
        }
        // The spec asks for 200pt, which pushes Stop and Reply off-screen on a
        // 49mm face. 116pt keeps the controls reachable without scrolling and
        // still shows several lines of output.
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: WD.R.row, style: .continuous)
                .fill(WD.C.console)
                .overlay(
                    RoundedRectangle(cornerRadius: WD.R.row, style: .continuous)
                        .strokeBorder(WD.C.hairline(0.07), lineWidth: 1)
                )
        )
        // A light circling the panel while output streams: the whole console
        // reads as live, not just the cursor.
        .overlay {
            if model.running {
                TracingBorder(color: WD.C.agent(agent), cornerRadius: WD.R.row)
            }
        }
    }

    /// Console lines are prefixed `› `, matching the handoff.
    private var consoleText: String {
        if model.entries.isEmpty {
            return model.statusLabel.isEmpty ? "› connecting to bridge…" : "› \(model.statusLabel)"
        }
        return model.entries.map { entry in
            switch entry.role {
            case .user: return "› \(entry.text)"
            case .agent: return entry.text
            case .denied: return "› blocked: \(entry.text)"
            case .error: return "› \(entry.text)"
            }
        }
        .joined(separator: "\n")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                confirmKill = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pause.fill")
                    Text("Pause").font(WD.F.body)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: WD.M.controlRow)
                .background(
                    RoundedRectangle(cornerRadius: WD.M.controlRow / 2, style: .continuous)
                        .fill(WD.C.surface)
                )
            }
            .pressable()
            .disabled(true)
            .opacity(0.45)

            Button {
                Haptics.failure()
                withAnimation(WD.Anim.signature) { confirmKill = true }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(WD.C.alert)
                    .frame(width: 70, height: WD.M.controlRow)
                    .background(
                        RoundedRectangle(cornerRadius: WD.M.controlRow / 2, style: .continuous)
                            .fill(WD.C.surface)
                    )
            }
            .pressable()
        }
    }

    /// Inline confirm, never a modal sheet.
    private var killConfirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kill this session?")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(WD.C.alert)
            Text("Uncommitted work in the sandbox is lost.")
                .font(.system(size: 13))
                .foregroundStyle(WD.C.bodyMuted)
            HStack(spacing: 10) {
                Button { kill() } label: {
                    Text("Kill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x1A0505))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(WD.C.alert))
                }
                .pressable()
                Button { withAnimation(WD.Anim.signature) { confirmKill = false } } label: {
                    Text("Cancel")
                        .font(WD.F.body)
                        .foregroundStyle(WD.C.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(WD.C.surface))
                }
                .pressable()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: WD.R.card, style: .continuous)
                .fill(WD.C.alertSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: WD.R.card, style: .continuous)
                        .strokeBorder(WD.C.alert.opacity(0.35), lineWidth: 1)
                )
        )
    }

    /// "claude-opus-5" is meaningless on a 49mm strip; "Opus" is not.
    private func shortModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        for name in ["opus", "sonnet", "haiku", "fable"] where lower.contains(name) {
            return name.capitalized
        }
        return raw.count > 14 ? String(raw.prefix(14)) : raw
    }

    private func kill() {
        confirmKill = false
        Haptics.failure()
        model.abortCurrentTurn()
    }
}
