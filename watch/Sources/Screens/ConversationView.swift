import SwiftUI
import Observation

@Observable
@MainActor
final class ConversationModel {
    struct Entry: Identifiable {
        enum Role { case user, agent, denied, error }
        let id = UUID()
        let role: Role
        var text: String
    }

    let agent: String
    let newSessionCwd: String?
    var sessionId: String?
    var entries: [Entry] = []
    var statusLabel = ""
    var running = false
    var summaryText: String?
    /// Rendered from the poll's level-triggered snapshot, never from events, so
    /// a reconnect shows what is actually still waiting.
    var pending: [PendingApproval] = []
    var respondingTo: String?
    /// The model the bridge reported this turn actually resolved to.
    var modelName = ""

    private(set) var turnId: String?
    private var cursor = 0
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    private var speaks = false
    private var speechRate = Constants.defaultSpeechRate

    init(agent: String, sessionId: String?, newSessionCwd: String? = nil) {
        self.agent = agent
        self.sessionId = sessionId
        self.newSessionCwd = newSessionCwd
    }

    func send(_ raw: String, ioMode: IOMode, speechRate: Double) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        speaks = ioMode.speaksReplies
        self.speechRate = speechRate
        entries.append(Entry(role: .user, text: text))
        summaryText = nil
        statusLabel = "Sending"
        running = true
        Haptics.click()

        Task {
            do {
                let result: SendResult
                if let sessionId {
                    result = try await BridgeClient.shared.send(
                        agent: agent, sessionId: sessionId, text: text, summarize: speaks)
                } else {
                    result = try await BridgeClient.shared.newSession(
                        agent: agent, cwd: newSessionCwd ?? "", text: text, summarize: speaks)
                }
                switch result {
                case .started(let turnId):
                    beginPolling(turnId: turnId)
                case .busy(let existing):
                    if let existing {
                        statusLabel = "Attaching to running turn"
                        beginPolling(turnId: existing)
                    } else {
                        fail("That session is busy; try again shortly.")
                    }
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Attaches to a turn started elsewhere (e.g. sent from the Speak screen),
    /// seeding the transcript with the prompt that launched it.
    func attach(turnId: String, prompt: String, ioMode: IOMode, speechRate: Double) {
        guard self.turnId == nil else { return }
        speaks = ioMode.speaksReplies
        self.speechRate = speechRate
        entries.append(Entry(role: .user, text: prompt))
        statusLabel = "Sending"
        running = true
        beginPolling(turnId: turnId)
    }

    /// Stops the turn on the Mac, not just locally.
    func abortCurrentTurn() {
        guard let turnId else { return }
        Task {
            try? await BridgeClient.shared.abort(turnId: turnId)
        }
    }

    /// Re-arm the poll loop after the app was suspended mid-turn.
    func resumeIfNeeded() {
        guard running, let turnId, pollTask == nil else { return }
        beginPolling(turnId: turnId, resetCursor: false)
        statusLabel = statusLabel.isEmpty ? "Catching up" : statusLabel
    }

    func stopPolling() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
    }

    private func beginPolling(turnId: String, resetCursor: Bool = true) {
        stopPolling()
        self.turnId = turnId
        if resetCursor { cursor = 0 }
        let gen = generation
        pollTask = Task { await pollLoop(gen: gen, turnId: turnId) }
    }

    private func pollLoop(gen: Int, turnId: String) async {
        var failures = 0
        while !Task.isCancelled && gen == generation {
            do {
                let poll = try await BridgeClient.shared.poll(turnId: turnId, cursor: cursor)
                failures = 0
                apply(poll)
                if poll.done {
                    pollTask = nil
                    return
                }
            } catch let error as BridgeError {
                if case .unknownTurn = error {
                    fail("Bridge restarted; re-send your message.")
                    pollTask = nil
                    return
                }
                failures += 1
                if failures > Constants.maxConsecutivePollFailures {
                    fail("Lost the bridge: \(error.localizedDescription)")
                    pollTask = nil
                    return
                }
                try? await Task.sleep(for: Constants.pollRetryDelay)
            } catch {
                failures += 1
                if failures > Constants.maxConsecutivePollFailures {
                    fail("Lost the bridge: \(error.localizedDescription)")
                    pollTask = nil
                    return
                }
                try? await Task.sleep(for: Constants.pollRetryDelay)
            }
        }
    }

    func respond(to approval: PendingApproval, allow: Bool) {
        guard let turnId, respondingTo == nil else { return }
        respondingTo = approval.approvalId
        Haptics.click()
        Task {
            defer { respondingTo = nil }
            do {
                _ = try await BridgeClient.shared.respond(
                    turnId: turnId, approvalId: approval.approvalId, allow: allow)
                // Optimistic clear; the next poll's snapshot is authoritative.
                pending.removeAll { $0.approvalId == approval.approvalId }
                statusLabel = allow ? "Approved" : "Declined"
            } catch {
                entries.append(Entry(role: .error, text: "Could not send: \(error.localizedDescription)"))
                Haptics.failure()
            }
        }
    }

    private func apply(_ poll: PollResponse) {
        for event in poll.events where event.seq >= cursor {
            switch event.type {
            case "session":
                if let id = event.sessionId { sessionId = id }
            case "status":
                if let label = event.label { statusLabel = label }
            case "model":
                if let name = event.name { modelName = name }
            case "text":
                if let chunk = event.chunk { appendAgentText(chunk) }
            case "denied":
                let what = event.detail?.isEmpty == false ? event.detail! : (event.tool ?? "a tool")
                entries.append(Entry(role: .denied, text: "Blocked: \(what)"))
            case "summary":
                summaryText = event.text
            case "done":
                finishTurn(fullText: event.fullText ?? "")
            case "error":
                fail(event.message ?? "Turn failed")
            case "approval":
                // Used only for the alert edge; the card renders from `pending`.
                Haptics.failure() // strong double-tap: this one needs you
            default:
                break
            }
        }
        cursor = max(cursor, poll.nextCursor)
        // Level-triggered: replace wholesale rather than mutating from events,
        // so a resolved approval can never linger and a missed event recovers.
        if let snapshot = poll.pending, snapshot != pending {
            pending = snapshot
        }
    }

    private func appendAgentText(_ chunk: String) {
        if let last = entries.indices.last, entries[last].role == .agent {
            entries[last].text += chunk
        } else {
            entries.append(Entry(role: .agent, text: chunk))
        }
    }

    private func finishTurn(fullText: String) {
        // Replace streamed fragments with the final reply for a clean transcript.
        if !fullText.isEmpty {
            if let last = entries.indices.last, entries[last].role == .agent {
                entries[last].text = fullText
            } else {
                entries.append(Entry(role: .agent, text: fullText))
            }
        }
        running = false
        statusLabel = ""
        pending = []
        Haptics.success()
        if speaks {
            Speaker.shared.speak(summaryText ?? fullText, rate: speechRate)
        }
    }

    private func fail(_ message: String) {
        entries.append(Entry(role: .error, text: message))
        running = false
        statusLabel = ""
        Haptics.failure()
    }
}

struct ConversationView: View {
    @State private var model: ConversationModel
    @AppStorage("ioMode") private var ioModeRaw = IOMode.voiceVoice.rawValue
    @AppStorage("speechRate") private var speechRate = Constants.defaultSpeechRate
    @Environment(\.scenePhase) private var scenePhase

    private let title: String

    init(session: SessionSummary) {
        _model = State(initialValue: ConversationModel(agent: session.agent, sessionId: session.id))
        title = session.label
        autoSend = nil
    }

    private let autoSend: String?

    init(agent: String, newWithCwd cwd: String, autoSend: String? = nil) {
        _model = State(initialValue: ConversationModel(agent: agent, sessionId: nil, newSessionCwd: cwd))
        title = "New \(agent.capitalized)"
        self.autoSend = autoSend
    }

    private var ioMode: IOMode { IOMode(rawValue: ioModeRaw) ?? .voiceVoice }

    var body: some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.entries) { entry in
                            entryView(entry)
                                .id(entry.id)
                        }
                        // Anything waiting on you sits above the status line.
                        ForEach(Array(model.pending.enumerated()), id: \.element.approvalId) { index, approval in
                            ApprovalCard(
                                approval: approval,
                                queuePosition: index + 1,
                                queueTotal: model.pending.count,
                                busy: model.respondingTo != nil,
                            ) { allow in
                                model.respond(to: approval, allow: allow)
                            }
                            .id(approval.approvalId)
                        }

                        if model.running && model.pending.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text(model.statusLabel.isEmpty ? "Working" : model.statusLabel)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .id("status")
                        }
                    }
                }
                .onChange(of: model.entries.count) {
                    withAnimation {
                        if model.running {
                            proxy.scrollTo("status", anchor: .bottom)
                        } else if let lastId = model.entries.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.pending.first?.approvalId) {
                    // .top, not .center: centering pulls the card up under the
                    // navigation title on a 44mm screen and clips its header.
                    if let first = model.pending.first?.approvalId {
                        withAnimation { proxy.scrollTo(first, anchor: .top) }
                    }
                }
            }

            TextFieldLink(prompt: Text("Message")) {
                Label(
                    ioMode == .voiceVoice || ioMode == .voiceText ? "Speak" : "Type",
                    systemImage: ioMode == .voiceVoice || ioMode == .voiceText ? "mic.fill" : "keyboard"
                )
                .frame(maxWidth: .infinity)
            } onSubmit: { value in
                model.send(value, ioMode: ioMode, speechRate: speechRate)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.running)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.resumeIfNeeded() }
        }
        .task {
            if let autoSend {
                model.send(autoSend, ioMode: .textText, speechRate: speechRate)
            }
        }
        .onDisappear {
            // Turn keeps running server-side; we just stop polling.
            model.stopPolling()
            Speaker.shared.stop()
        }
    }

    @ViewBuilder
    private func entryView(_ entry: ConversationModel.Entry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .font(.footnote.bold())
                .foregroundStyle(.cyan)
        case .agent:
            Text(entry.text)
                .font(.footnote)
        case .denied:
            Label(entry.text, systemImage: "hand.raised.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
