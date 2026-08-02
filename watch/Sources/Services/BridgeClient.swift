import Foundation
import os

enum BridgeError: Error, LocalizedError {
    case notConfigured
    case unauthorized
    case unknownTurn
    case busy(existingTurnId: String?)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No bridge URL configured"
        case .unauthorized: return "Bridge rejected the token"
        case .unknownTurn: return "Bridge restarted; re-send your message"
        case .busy: return "That session already has a turn running"
        case .http(let code): return "Bridge error (\(code))"
        }
    }
}

enum SendResult {
    case started(turnId: String)
    case busy(existingTurnId: String?)
}

actor BridgeClient {
    static let shared = BridgeClient()

    private let session: URLSession
    private let log = Logger(subsystem: "com.donalleniii.wristdeck", category: "bridge")
    private var baseURL: URL?
    private var token = ""
    private var candidates: [String] = []
    private var configured = false

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = Constants.requestTimeout
        // waitsForConnectivity would park an unreachable request for
        // timeoutIntervalForResource (days) and the UI would spin forever.
        // Fail fast instead so the user sees a real error.
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForResource = Constants.resourceTimeout
        session = URLSession(configuration: cfg)
    }

    /// Lazily configures from Settings overrides / Config.plist on first use,
    /// so early view loads never race explicit configuration.
    private func ensureConfigured() async {
        guard !configured else { return }
        await reconfigure()
    }

    /// Reads Settings overrides / Config.plist and re-races the candidates.
    func reconfigure() async {
        let bundleConfig = BundleConfig.load()
        let defaults = UserDefaults.standard
        let urlOverride = (defaults.string(forKey: "bridgeURLOverride") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenOverride = (defaults.string(forKey: "tokenOverride") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await configure(
            candidates: urlOverride.isEmpty ? bundleConfig.candidates : [urlOverride],
            token: tokenOverride.isEmpty ? bundleConfig.token : tokenOverride
        )
    }

    /// Races /health across every candidate; first responder becomes the base URL.
    func configure(candidates rawCandidates: [String], token: String) async {
        configured = true
        self.token = token
        candidates = rawCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        baseURL = nil
        lastProbeReport = [:]
        guard !candidates.isEmpty else { return }
        if let winner = await raceHealth() {
            baseURL = winner
            log.info("bridge base: \(winner.absoluteString, privacy: .public)")
        } else {
            // Nothing answered; keep the first candidate so requests surface real errors.
            baseURL = URL(string: candidates[0])
            log.warning("no bridge answered /health; defaulting to first candidate")
        }
    }

    /// Per-candidate outcome from the last race, for the Settings diagnostics view.
    private(set) var lastProbeReport: [String: String] = [:]

    func diagnostics() async -> [(url: String, result: String)] {
        candidates.map { ($0, lastProbeReport[$0] ?? "not tried") }
    }

    var activeBase: String {
        get async { baseURL?.absoluteString ?? "" }
    }

    func healthOK() async -> Bool {
        guard let base = baseURL else { return false }
        return await probe(base, label: base.absoluteString).1 != nil
    }

    func sessions() async throws -> [SessionSummary] {
        await ensureConfigured()
        let data = try await get("/sessions")
        return try JSONDecoder().decode(SessionsResponse.self, from: data).sessions
    }

    /// Which model each agent runs, and what it can switch to.
    func models() async -> [String: AgentModels] {
        await ensureConfigured()
        guard let data = try? await get("/models"),
              let decoded = try? JSONDecoder().decode([String: AgentModels].self, from: data)
        else { return [:] }
        return decoded
    }

    @discardableResult
    func setModel(agent: String, model: String) async -> Bool {
        await ensureConfigured()
        guard var request = try? makeRequest("/models") else { return false }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["agent": agent, "model": model])
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Proof of work: the Mac's screen as it looked when the turn finished.
    func proofShot(turnId: String) async -> Data? {
        await ensureConfigured()
        return try? await get("/turns/\(turnId)/shot")
    }

    func autoOpenEnabled() async -> Bool {
        await ensureConfigured()
        guard
            let data = try? await get("/settings"),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["autoOpen"] as? Bool
        else { return true }
        return value
    }

    func setAutoOpen(_ enabled: Bool) async {
        await ensureConfigured()
        guard var request = try? makeRequest("/settings") else { return }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["autoOpen": enabled])
        _ = try? await session.data(for: request)
    }

    /// What the Mac is doing right now, plus what just finished.
    func activitySnapshot() async throws -> ActivityResponse {
        await ensureConfigured()
        let data = try await get("/activity")
        return try JSONDecoder().decode(ActivityResponse.self, from: data)
    }

    func activity() async throws -> [ActivityItem] {
        try await activitySnapshot().active
    }

    func send(agent: String, sessionId: String, text: String, summarize: Bool, model: String = "") async throws -> SendResult {
        await ensureConfigured()
        var body: [String: Any] = ["text": text, "summarize": summarize]
        if !model.isEmpty { body["model"] = model }
        return try await start(path: "/sessions/\(agent)/\(sessionId)/message", body: body)
    }

    func newSession(agent: String, cwd: String, text: String, summarize: Bool, model: String = "") async throws -> SendResult {
        await ensureConfigured()
        var body: [String: Any] = ["text": text, "summarize": summarize, "cwd": cwd]
        if !model.isEmpty { body["model"] = model }
        return try await start(path: "/sessions/\(agent)/new", body: body)
    }

    /// Answers a parked approval. Returns true if the decision was recorded
    /// (including an idempotent repeat of the same decision).
    func respond(turnId: String, approvalId: String, allow: Bool) async throws -> Bool {
        await ensureConfigured()
        var request = try makeRequest("/turns/\(turnId)/approvals/\(approvalId)")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["decision": allow ? "allow" : "deny"])
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return true }
        if code == 401 { throw BridgeError.unauthorized }
        return false
    }

    func abort(turnId: String) async throws {
        await ensureConfigured()
        var request = try makeRequest("/turns/\(turnId)/abort")
        request.httpMethod = "POST"
        _ = try await session.data(for: request)
    }

    func poll(turnId: String, cursor: Int) async throws -> PollResponse {
        await ensureConfigured()
        let data = try await get("/turns/\(turnId)/events?cursor=\(cursor)")
        return try JSONDecoder().decode(PollResponse.self, from: data)
    }

    // MARK: - internals

    private func start(path: String, body: [String: Any]) async throws -> SendResult {
        var request = try makeRequest(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 202:
            return .started(turnId: try JSONDecoder().decode(TurnStartResponse.self, from: data).turnId)
        case 409:
            let busyBody = try? JSONDecoder().decode(BridgeErrorBody.self, from: data)
            return .busy(existingTurnId: busyBody?.turnId)
        case 401:
            throw BridgeError.unauthorized
        default:
            throw BridgeError.http(code)
        }
    }

    private func get(_ path: String) async throws -> Data {
        let request = try makeRequest(path)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 401: throw BridgeError.unauthorized
        case 404: throw BridgeError.unknownTurn
        default: throw BridgeError.http(code)
        }
    }

    private func makeRequest(_ path: String) throws -> URLRequest {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base) else {
            throw BridgeError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func raceHealth() async -> URL? {
        // Probe every candidate and record why each failed, so Settings can
        // show the user which path is broken rather than a bare "not connected".
        var winner: URL?
        await withTaskGroup(of: (String, URL?, String).self) { group in
            for candidate in candidates {
                guard let url = URL(string: candidate) else {
                    lastProbeReport[candidate] = "bad URL"
                    continue
                }
                group.addTask { await self.probe(url, label: candidate) }
            }
            for await (label, result, note) in group {
                lastProbeReport[label] = note
                if winner == nil, let ok = result { winner = ok }
            }
        }
        return winner
    }

    private func probe(_ base: URL, label: String) async -> (String, URL?, String) {
        guard let url = URL(string: "/health", relativeTo: base) else {
            return (label, nil, "bad URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Constants.healthProbeTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return (label, base, "reachable") }
            if code == 401 { return (label, nil, "bad token") }
            return (label, nil, "HTTP \(code)")
        } catch {
            let nsError = error as NSError
            let note: String
            switch nsError.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                note = "name not found"
            case NSURLErrorCannotConnectToHost:
                note = "refused"
            case NSURLErrorTimedOut:
                note = "timed out"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                note = "no network"
            default:
                note = "error \(nsError.code)"
            }
            return (label, nil, note)
        }
    }
}
