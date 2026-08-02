import Foundation

struct SessionSummary: Codable, Identifiable, Hashable {
    let agent: String
    let id: String
    let label: String
    let cwd: String
    let lastActivity: Double // epoch ms

    var folderName: String {
        (cwd as NSString).lastPathComponent
    }

    var relativeTime: String {
        let date = Date(timeIntervalSince1970: lastActivity / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SessionsResponse: Codable {
    let sessions: [SessionSummary]
}

/// One in-flight turn on the Mac, from GET /activity.
struct ActivityItem: Codable, Identifiable, Equatable {
    let turnId: String
    let agent: String
    let sessionId: String
    let status: String
    let startedAt: Double
    let elapsedMs: Double
    let pending: [PendingApproval]

    var id: String { turnId }
}

/// A turn that just finished, with a screenshot of the Mac if one was captured.
struct FinishedItem: Codable, Identifiable, Equatable {
    let turnId: String
    let agent: String
    let outcome: String
    let summary: String
    let cwd: String
    let touched: [String]
    let finishedAt: Double
    let durationMs: Double
    let hasShot: Bool?

    var id: String { turnId }
    var showsProof: Bool { hasShot == true }
}

struct ModelOption: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
}

struct AgentModels: Codable, Equatable {
    let options: [ModelOption]
    let current: String
}

struct ActivityResponse: Codable {
    let active: [ActivityItem]
    let recent: [FinishedItem]?
}

/// One event from the bridge. The union is decoded leniently: `type` decides
/// which optional payload fields matter; unknown types are ignored upstream.
struct WristEvent: Codable {
    let seq: Int
    let ts: Double
    let type: String
    let agent: String?
    let sessionId: String?
    let label: String?
    let chunk: String?
    let tool: String?
    let detail: String?
    let text: String?
    let fullText: String?
    let numTurns: Int?
    let costUsd: Double?
    let message: String?
    let name: String?
}

/// An action parked on the Mac waiting for a tap here.
struct PendingApproval: Codable, Identifiable, Equatable {
    let approvalId: String
    let tool: String
    let summary: String
    let detail: String
    let cwd: String
    let risk: String
    let costHint: String?
    let createdAt: Double
    let expiresAt: Double

    var id: String { approvalId }

    var folderName: String {
        cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
    }

    func secondsRemaining(now: Date = Date()) -> Int {
        max(0, Int(expiresAt / 1000 - now.timeIntervalSince1970))
    }
}

struct PollResponse: Codable {
    let events: [WristEvent]
    let nextCursor: Int
    let done: Bool
    /// Optional so the app still decodes against a bridge that predates
    /// approvals; a missing field must never break the whole response.
    let pending: [PendingApproval]?
}

struct TurnStartResponse: Codable {
    let turnId: String
}

struct BridgeErrorBody: Codable {
    let error: String
    let turnId: String?
}

enum IOMode: String, CaseIterable, Identifiable {
    case voiceVoice
    case voiceText
    case textVoice
    case textText

    var id: String { rawValue }

    var label: String {
        switch self {
        case .voiceVoice: return "Voice in, voice out"
        case .voiceText: return "Voice in, text out"
        case .textVoice: return "Text in, voice out"
        case .textText: return "Text in, text out"
        }
    }

    var speaksReplies: Bool {
        self == .voiceVoice || self == .textVoice
    }
}

struct BundleConfig {
    let bridgeURL: String     // public Tailscale Funnel URL; works anywhere
    let tailscaleURL: String  // Mac's tailnet IP; works if watch traffic reaches the tailnet
    let localURL: String      // mDNS .local name; same Wi-Fi only
    let lanURL: String        // raw LAN IP; same Wi-Fi, skips mDNS resolution
    let token: String

    /// Ordered best-to-worst reach. The client health-races these and keeps the
    /// first that answers, so listing a candidate that cannot work is harmless.
    var candidates: [String] { [bridgeURL, tailscaleURL, lanURL, localURL] }

    static func load() -> BundleConfig {
        guard
            let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            return BundleConfig(
                bridgeURL: "", tailscaleURL: "", localURL: "http://127.0.0.1:8787", lanURL: "", token: "")
        }
        return BundleConfig(
            bridgeURL: dict["BridgeURL"] ?? "",
            tailscaleURL: dict["TailscaleURL"] ?? "",
            localURL: dict["LocalURL"] ?? "",
            lanURL: dict["LanURL"] ?? "",
            token: dict["Token"] ?? ""
        )
    }
}
