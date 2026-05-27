import Foundation

struct ClaudeCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let rateLimitTier: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
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

    var burnRatePerHour: Double? {
        guard let secs = elapsed, secs > 300 else { return nil }
        return usedPercent / (secs / 3600)
    }

    var projectedUsageAtReset: Double? {
        guard let rate = burnRatePerHour, let remaining = timeUntilReset else { return nil }
        return usedPercent + rate * (remaining / 3600)
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
    let total = Int(max(0, interval))
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60

    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(minutes)m"
}
