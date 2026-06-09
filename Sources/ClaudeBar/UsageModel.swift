import Foundation

// Deliberately minimal: only the access token is ever parsed from the keychain
// item — the refresh token and the rest of the CLI's credential JSON are ignored.
struct ClaudeCredentials {
    let accessToken: String
}

struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthWindow?
    let sevenDay: OAuthWindow?
    let sevenDaySonnet: OAuthWindow?
    let sevenDayOpus: OAuthWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
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
        return wait > 60 ? wait : nil
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
        guard let window, let utilization = window.utilization else { return nil }
        let resetsAt: Date? = {
            guard let str = window.resetsAt, !str.isEmpty else { return nil }
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: str) { return d }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: str)
        }()
        return RateWindow(usedPercent: utilization, windowDuration: durationHours * 3600, resetsAt: resetsAt)
    }
}

struct UsageSnapshot {
    let session: RateWindow
    let weekly: RateWindow?
    let sonnetWeekly: RateWindow?
    let opusWeekly: RateWindow?
    let fetchedAt: Date

    init(session: RateWindow, weekly: RateWindow?, sonnetWeekly: RateWindow?, opusWeekly: RateWindow?) {
        self.session = session
        self.weekly = weekly
        self.sonnetWeekly = sonnetWeekly
        self.opusWeekly = opusWeekly
        self.fetchedAt = Date()
    }

    static func from(_ response: OAuthUsageResponse) -> UsageSnapshot? {
        guard let session = RateWindow.from(response.fiveHour, durationHours: 5) else { return nil }
        return UsageSnapshot(
            session: session,
            weekly: RateWindow.from(response.sevenDay, durationHours: 168),
            sonnetWeekly: RateWindow.from(response.sevenDaySonnet, durationHours: 168),
            opusWeekly: RateWindow.from(response.sevenDayOpus, durationHours: 168)
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
