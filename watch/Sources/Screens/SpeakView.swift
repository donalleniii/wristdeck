import SwiftUI

/// 03 Speak — voice is the primary input.
/// The prototype fakes dictation; this uses the real system input controller via
/// TextFieldLink, which offers dictation, scribble, and keyboard with no mic
/// entitlement. The listening waveform shows while that sheet is up.
struct SpeakView: View {
    let agent: String
    /// Mutable: the picker below the fold retargets without leaving the screen.
    @State var folder: AppModel.RecentFolder
    /// When set, the prompt continues an existing session instead of starting one.
    var continuingSessionId: String?

    init(agent: String, folder: AppModel.RecentFolder, continuingSessionId: String? = nil) {
        self.agent = agent
        _folder = State(initialValue: folder)
        self.continuingSessionId = continuingSessionId
    }

    @Environment(AppModel.self) private var appModel
    @AppStorage("speechRate") private var speechRate = Constants.defaultSpeechRate

    @State private var transcript = ""
    @State private var listening = false
    @State private var sending = false
    @State private var launched: LaunchedSession?
    @State private var model = ""
    @State private var modelOptions: [ModelOption] = []

    private var modelLabel: String {
        modelOptions.first { $0.id == model }?.label ?? model
    }

    private struct LaunchedSession: Hashable {
        let sessionId: String
        let agent: String
        let title: String
        let turnId: String
        let prompt: String
    }

    private var agentName: String { agent == "codex" ? "Codex" : "Claude" }

    private var hint: String {
        if sending { return "Sending to \(agentName)…" }
        return listening ? "Listening…" : "Tell \(agentName) what to build"
    }

    var body: some View {
        // Vertical paging, not a scroll view: page one is the whole decision and
        // always fills the screen exactly, page two changes the folder. Trying to
        // size a scrolling pane by hand fought the nav bar and bled content.
        TabView {
            speakPane.tag(0)
            folderPane.tag(1)
        }
        .tabViewStyle(.verticalPage)
        .background(WD.C.bg)
        // No nav title: a TabView page draws underneath the title bar, so it
        // collided with the destination chip. The chip says where, the hint
        // says who, and the flow already made the agent explicit.
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $launched) { launch in
            SessionView(
                sessionId: launch.sessionId,
                agent: launch.agent,
                title: launch.title,
                attachTurnId: launch.turnId,
                openingPrompt: launch.prompt,
            )
        }
        .task { await loadModels() }
    }

    /// One screen, one job: talk.
    ///
    /// The previous version stacked a config chip, a hint, the orb, a button and
    /// a path footer. On a real wrist the chip collided with the system back
    /// button and clock and truncated to "do... Son...", which is noise sitting
    /// on top of the only thing that matters. Context moved to the config page
    /// and to one quiet line at the bottom; the ENTIRE screen is now the button.
    private var speakPane: some View {
        TextFieldLink(prompt: Text("Tell \(agentName) what to build")) {
            VStack(spacing: 10) {
                // Clears the system back chevron and clock, which draw over a
                // TabView page.
                Spacer(minLength: 26)

                ZStack {
                    if sending {
                        PulseRings(color: WD.C.agent(agent), diameter: 132)
                        AgentOrb(color: WD.C.agent(agent), mode: .working, diameter: 132)
                    } else if listening {
                        Waveform(color: WD.C.agent(agent))
                    } else {
                        AgentOrb(color: WD.C.agent(agent), mode: .idle, diameter: 138)
                        // Without a Speak button there is nothing saying "tap".
                        // The mic at the orb's centre is the affordance, and it
                        // keeps the screen to a single focal point.
                        Image(systemName: "mic.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: WD.C.agent(agent).opacity(0.6), radius: 12)
                    }
                }
                .frame(maxHeight: .infinity)

                Text(sending ? transcript : hint)
                    .font(.system(size: sending ? 12 : 15, weight: .semibold))
                    .foregroundStyle(sending ? WD.C.textSecondary : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)

                // Quiet, non-interactive. Tap-to-change lives one swipe down.
                Text(contextLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WD.C.textQuaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle()) // the whole pane is the tap target
        } onSubmit: { value in
            listening = false
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            transcript = trimmed
            send()
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .simultaneousGesture(TapGesture().onEnded {
            guard !sending else { return }
            listening = true
            Haptics.click()
        })
        .padding(.horizontal, WD.M.edge)
        .springEntrance()
    }

    /// "bridge · Sonnet" — everything you need to know, nothing to fight with.
    private var contextLine: String {
        let where_ = folder.name
        return model.isEmpty ? where_ : "\(where_) · \(modelLabel)"
    }

    /// Page two: change where this runs. Optional by design.
    private var folderPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WD.M.rowGap) {
            // Model first: it is the thing you are most likely to change
            // deliberately, and it costs one swipe from the mic.
            if modelOptions.count > 1 {
                SectionLabel("Model")
                ForEach(modelOptions) { option in
                    Button { chooseModel(option) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label)
                                    .font(WD.F.row)
                                    .foregroundStyle(option.id == model ? .white : WD.C.textSecondary)
                                Text(option.note)
                                    .font(WD.F.meta)
                                    .foregroundStyle(WD.C.textQuaternary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if option.id == model {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(WD.C.agent(agent))
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: WD.M.recentRow)
                        .background(
                            RoundedRectangle(cornerRadius: WD.R.recentRow, style: .continuous)
                                .fill(option.id == model ? WD.C.surfaceHover : WD.C.surface)
                        )
                    }
                    .pressable()
                }
            }

            SectionLabel("Work in")

            ForEach(Array(appModel.recents.prefix(5))) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.name)
                                .font(WD.F.row)
                                .foregroundStyle(option.path == folder.path ? .white : WD.C.textSecondary)
                                .lineLimit(1)
                            Text(option.when)
                                .font(WD.F.meta)
                                .foregroundStyle(WD.C.textQuaternary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if option.path == folder.path {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(WD.C.running)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: WD.M.recentRow)
                    .background(
                        RoundedRectangle(cornerRadius: WD.R.recentRow, style: .continuous)
                            .fill(option.path == folder.path ? WD.C.surfaceHover : WD.C.surface)
                    )
                }
                .pressable()
            }

            Button { choose(AppModel.RecentFolder(name: "Mac home folder", path: "", when: "default")) } label: {
                Text("Mac home folder")
                    .font(.system(size: 15, weight: .semibold))
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
            .padding(.horizontal, WD.M.edge)
            .padding(.bottom, WD.M.bottomSafe)
        }
    }

    private func choose(_ option: AppModel.RecentFolder) {
        Haptics.click()
        appModel.folder = option
        folder = option
    }

    /// Switching here sets it for this run AND becomes the new default, because
    /// on a watch nobody wants to re-pick the same model every single time.
    private func chooseModel(_ option: ModelOption) {
        Haptics.click()
        model = option.id
        Task { await BridgeClient.shared.setModel(agent: agent, model: option.id) }
    }

    private func loadModels() async {
        let catalog = await BridgeClient.shared.models()
        guard let mine = catalog[agent] else { return }
        modelOptions = mine.options
        if model.isEmpty { model = mine.current }
    }

    private func send() {
        let prompt = transcript
        sending = true
        Haptics.success()
        Task {
            defer { sending = false }
            do {
                let result: SendResult
                if let continuingSessionId {
                    result = try await BridgeClient.shared.send(
                        agent: agent, sessionId: continuingSessionId, text: prompt,
                        summarize: true, model: model)
                } else {
                    result = try await BridgeClient.shared.newSession(
                        agent: agent, cwd: folder.path, text: prompt,
                        summarize: true, model: model)
                }
                let turnId: String
                switch result {
                case .started(let id): turnId = id
                case .busy(let existing):
                    guard let existing else { return }
                    turnId = existing
                }
                launched = LaunchedSession(
                    sessionId: continuingSessionId ?? "",
                    agent: agent,
                    title: agentName,
                    turnId: turnId,
                    prompt: prompt,
                )
            } catch {
                Haptics.failure()
            }
        }
    }
}

/// Seven bars in the agent color, scaling 0.25 -> 1 on a staggered loop.
struct Waveform: View {
    let color: Color
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 10, height: 86)
                    .scaleEffect(y: animating ? 1 : 0.25, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.55 + Double(index % 3) * 0.18)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.07),
                        value: animating,
                    )
            }
        }
        .frame(height: 86)
        .onAppear { animating = true }
    }
}
