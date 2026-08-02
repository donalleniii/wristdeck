import Foundation

// All tunables live here. Tune on-wrist, then commit new values.
enum Constants {
    static let requestTimeout: TimeInterval = 40      // covers the bridge's 25s long-poll hold
    static let resourceTimeout: TimeInterval = 120    // hard ceiling; prevents endless spinners
    static let healthProbeTimeout: TimeInterval = 6
    static let pollRetryDelay: Duration = .seconds(1)
    static let maxConsecutivePollFailures = 6
    static let defaultSpeechRate = 0.45
    static let sessionListLimit = 40
    static let recentCwdLimit = 6
}
