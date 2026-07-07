import Foundation

// Deliberately minimal: only the access token is ever parsed from the keychain
// item — the refresh token and the rest of the CLI's credential JSON are ignored.
struct ClaudeCredentials {
    let accessToken: String
}

struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthWindow?
    let sevenDay: OAuthWindow?
    let limits: [OAuthLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

struct OAuthWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// One entry of the `limits` array the usage endpoint began returning with the Sonnet-5
/// rollout. It supersedes the fixed `seven_day_sonnet`/`seven_day_opus` keys (now always
/// null): the per-model weekly cap is a single `weekly_scoped` entry whose `scope.model`
/// names whichever model you're currently metered against, so we no longer hardcode names.
struct OAuthLimit: Decodable {
    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let scope: OAuthScope?

    enum CodingKeys: String, CodingKey {
        case kind, percent, scope
        case resetsAt = "resets_at"
    }
}

struct OAuthScope: Decodable {
    let model: OAuthModel?
}

struct OAuthModel: Decodable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

enum WindowKind {
    case session
    case weekly
}

/// Pace verdict for a rate window: how actual consumption compares to an even burn
/// across the window. Single source of truth for the chip, the deviation band, the
/// footer line, and the Recommender, so they can never disagree.
enum PaceTier {
    case early      // no trustworthy forecast yet
    case idle       // weekly only: a large share of the paid quota will expire unused
    case onPace     // projected to land with a healthy margin
    case hot        // tight margin projected at reset
    case runsOut    // projected to exhaust before reset, or already exhausted

    var word: String {
        switch self {
        case .early: return "Early"
        case .idle: return "Idle"
        case .onPace: return "On pace"
        case .hot: return "Hot"
        case .runsOut: return "Runs out"
        }
    }

    var symbol: String {
        switch self {
        case .early: return "minus.circle"
        case .idle: return "tortoise"
        case .onPace: return "checkmark.circle.fill"
        case .hot: return "hare"
        case .runsOut: return "flame.fill"
        }
    }
}

struct RateWindow {
    let usedPercent: Double
    let windowDuration: TimeInterval
    let resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    var timeUntilReset: TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSinceNow) }
    }

    private var elapsed: TimeInterval? {
        guard let start = resetsAt?.addingTimeInterval(-windowDuration) else { return nil }
        return max(60, Date().timeIntervalSince(start))
    }

    func waitToReachProjected(_ targetPercent: Double) -> TimeInterval? {
        guard let elapsed, let resetIn = timeUntilReset else { return nil }
        let wait = usedPercent * (elapsed + resetIn) / targetPercent - elapsed
        return (wait > 60 && wait < resetIn) ? wait : nil
    }

    var waitToStabilize: TimeInterval? { waitToReachProjected(100) }

    var burnRatePerHour: Double? {
        guard let secs = elapsed, secs > 300 else { return nil }
        return usedPercent / (secs / 3600)
    }

    var projectedUsageAtReset: Double? {
        guard let rate = burnRatePerHour, let remaining = timeUntilReset else { return nil }
        return usedPercent + rate * (remaining / 3600)
    }

    /// Share of the window already behind us, 0…1.
    var elapsedFraction: Double? {
        guard let elapsed, windowDuration > 0 else { return nil }
        return min(1, max(0, elapsed / windowDuration))
    }

    /// Unclamped: goes negative when the window is projected to exhaust before reset,
    /// so severity is never silently flattened to a calm "0% left".
    var projectedLeftAtReset: Double? {
        projectedUsageAtReset.map { 100 - $0 }
    }

    /// Time until the quota hits 100% at the average burn rate so far.
    var timeToExhaustion: TimeInterval? {
        guard let rate = burnRatePerHour, rate > 0 else { return nil }
        return remainingPercent / rate * 3600
    }

    func paceTier(kind: WindowKind) -> PaceTier {
        guard resetsAt != nil else { return .early }
        // Measured exhaustion is a fact, not a forecast — don't wait out the
        // burn-rate warmup before going red.
        if remainingPercent < 5 { return .runsOut }
        guard let projected = projectedUsageAtReset,
              let fraction = elapsedFraction else { return .early }
        // Too little of the window elapsed to trust a whole-window average — unless
        // usage is already so high that even an early forecast is clearly real.
        let earlyGate = kind == .session ? 0.10 : 0.05
        if fraction < earlyGate && usedPercent < 50 { return .early }
        if projected >= 100 {
            // Anti-flap: minutes after a reset the average blows up on a tiny
            // denominator; don't go red until real usage or time backs it.
            if usedPercent < 20 && fraction < 0.10 { return .hot }
            return .runsOut
        }
        if projected >= 85 { return .hot }
        if kind == .weekly && projected < 60 && fraction >= 0.25 { return .idle }
        return .onPace
    }

    static func from(_ window: OAuthWindow?, durationHours: Double) -> RateWindow? {
        guard let window else { return nil }
        return from(percent: window.utilization, resetsAt: window.resetsAt, durationHours: durationHours)
    }

    /// Build from a bare percent + reset string — shared by the legacy top-level windows and
    /// the newer `limits` entries, which report `percent` rather than `utilization`.
    static func from(percent: Double?, resetsAt: String?, durationHours: Double) -> RateWindow? {
        guard let percent else { return nil }
        return RateWindow(usedPercent: percent, windowDuration: durationHours * 3600, resetsAt: parseDate(resetsAt))
    }

    private static func parseDate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }
}

struct UsageSnapshot {
    let session: RateWindow
    let weekly: RateWindow?
    /// The per-model weekly cap (`weekly_scoped`), scoped to whichever model the plan is
    /// currently metering — its name lives in `scopedModelName`. Replaces the old fixed
    /// Sonnet/Opus windows, which the endpoint stopped populating after the Sonnet-5 rollout.
    let scopedWeekly: RateWindow?
    let scopedModelName: String?
    let fetchedAt: Date

    init(session: RateWindow, weekly: RateWindow?, scopedWeekly: RateWindow?, scopedModelName: String?) {
        self.session = session
        self.weekly = weekly
        self.scopedWeekly = scopedWeekly
        self.scopedModelName = scopedModelName
        self.fetchedAt = Date()
    }

    static func from(_ response: OAuthUsageResponse) -> UsageSnapshot? {
        guard let session = RateWindow.from(response.fiveHour, durationHours: 5) else { return nil }
        let scoped = response.limits?.first { $0.kind == "weekly_scoped" }
        return UsageSnapshot(
            session: session,
            weekly: RateWindow.from(response.sevenDay, durationHours: 168),
            scopedWeekly: RateWindow.from(percent: scoped?.percent, resetsAt: scoped?.resetsAt, durationHours: 168),
            scopedModelName: scoped?.scope?.model?.displayName
        )
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    guard interval.isFinite else { return "—" }
    let total = Int(max(0, interval))
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60

    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(minutes)m"
}
