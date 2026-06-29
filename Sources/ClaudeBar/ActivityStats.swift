import Foundation

/// When the user actually engages Claude Code, derived from ~/.claude/history.jsonl —
/// one entry is appended there per submitted prompt. This is the cheapest, most direct
/// "when do I work" signal: it drives the activity chart and lets the Recommender stop
/// raising alarms about deadlines that land in hours the user is rarely at the keyboard.
struct ActivityProfile: Sendable {
    /// Prompt count per hour-of-day (0…23), local time. Always 24 entries.
    let hourCounts: [Int]
    /// Prompt count per weekday (index 0 = Sunday … 6 = Saturday) × hour-of-day. 7×24.
    let weekdayHourCounts: [[Int]]
    let totalPrompts: Int
    let distinctDays: Int
    let firstPrompt: Date?
    let lastPrompt: Date?

    static let empty = ActivityProfile(
        hourCounts: Array(repeating: 0, count: 24),
        weekdayHourCounts: Array(repeating: Array(repeating: 0, count: 24), count: 7),
        totalPrompts: 0, distinctDays: 0, firstPrompt: nil, lastPrompt: nil
    )

    /// An hour counts as "active" once it reaches at least this share of a typical busy hour.
    /// 0.15 cleanly separates a real working hour from the stray late-night one-off.
    static let activeThreshold = 0.15

    /// Off-hours are only claimed for a contiguous inactive stretch at least this long, so a
    /// single sparse hour in the middle of the day is never treated as "off-hours". The UI
    /// and the Recommender both derive their notion of off-hours from this, so they agree.
    static let minDeadRun = 3

    /// Enough signal to trust the active/dead-hour split. Below this the daily rhythm is
    /// noise, so the Recommender must not suppress anything and the UI shows a caveat.
    var hasEnoughData: Bool { totalPrompts >= 40 && distinctDays >= 5 }

    var peakHourCount: Int { hourCounts.max() ?? 0 }

    /// Reference level for "a typical busy hour": the second-highest hourly count, not the
    /// max. A single outlier burst — e.g. an unattended/scheduled run dumping many prompts in
    /// one hour — would otherwise inflate the denominator and push genuine working hours
    /// below the threshold, wrongly marking them inactive.
    private var referenceLevel: Double {
        let sorted = hourCounts.sorted(by: >)
        let top = sorted.first ?? 0
        let second = sorted.dropFirst().first ?? 0
        return Double(second > 0 ? second : top)
    }

    /// How busy this hour is relative to a typical busy hour, 0…1+ (can exceed 1 for an
    /// outlier hour) — the shape of the daily rhythm.
    func intensity(hour: Int) -> Double {
        let reference = referenceLevel
        guard reference > 0, (0..<24).contains(hour) else { return 0 }
        return Double(hourCounts[hour]) / reference
    }

    func isActive(hour: Int) -> Bool { intensity(hour: hour) >= Self.activeThreshold }

    var activeHours: Set<Int> { Set((0..<24).filter { isActive(hour: $0) }) }

    /// Maximal runs of consecutive inactive hours around the 24-hour clock, including a run
    /// that wraps past midnight. Each is (start hour, length). Empty when every hour is
    /// active; a single full-day run when every hour is inactive.
    private func inactiveRuns() -> [(start: Int, len: Int)] {
        let active = (0..<24).map { isActive(hour: $0) }
        guard let firstActive = (0..<24).first(where: { active[$0] }) else {
            return active.contains(false) ? [(0, 24)] : []
        }
        // Walk a full circle starting from an active hour, so no run straddles the array end.
        var runs: [(start: Int, len: Int)] = []
        var i = 0
        while i < 24 {
            let hour = (firstActive + i) % 24
            if active[hour] { i += 1; continue }
            var len = 0
            while i < 24, !active[(firstActive + i) % 24] { len += 1; i += 1 }
            runs.append((start: (firstActive + (i - len)) % 24, len: len))
        }
        return runs
    }

    /// The hours that belong to a genuine off-hours stretch (a contiguous inactive run of at
    /// least `minDeadRun` hours). The single source of truth shared by `isDeadTime` and
    /// `deadRangeDescription`, so the recommendation and the displayed copy can never disagree.
    var offHours: Set<Int> {
        guard hasEnoughData else { return [] }
        var hours = Set<Int>()
        for run in inactiveRuns() where run.len >= Self.minDeadRun {
            for k in 0..<run.len { hours.insert((run.start + k) % 24) }
        }
        return hours
    }

    /// True when the given instant lands in an off-hours stretch — the hook the Recommender
    /// uses to discount deadlines (a 5-hour window resetting at 3 a.m. is moot if you stopped
    /// at 1 a.m.).
    func isDeadTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        offHours.contains(calendar.component(.hour, from: date))
    }

    /// The longest off-hours stretch rendered as a human range like "1:00–11:00" (end = the
    /// hour activity resumes). nil when there is no meaningful dead stretch — in which case
    /// `isDeadTime` is also always false, so the UI's "no off-hours" copy stays honest.
    var deadRangeDescription: String? {
        guard hasEnoughData else { return nil }
        guard let longest = inactiveRuns()
            .filter({ $0.len >= Self.minDeadRun })
            .max(by: { $0.len < $1.len }) else { return nil }
        let endHour = (longest.start + longest.len) % 24
        return String(format: "%d:00–%d:00", longest.start, endHour)
    }
}

enum ActivityHistory {
    /// Only the tail of history.jsonl is read: the daily rhythm only needs recent activity,
    /// and the file grows unbounded (Claude Code appends one line per prompt forever, and a
    /// pasted block can make a single line multi-KB). Bounds the work regardless of size.
    static let maxBytes = 1_048_576

    /// Parse ~/.claude/history.jsonl into an ActivityProfile. Each line is one submitted
    /// prompt with a `timestamp` in epoch milliseconds; everything else is ignored.
    /// Pure filesystem work — safe to call from a background task.
    static func load(calendar: Calendar = .current) -> ActivityProfile {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/history.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return .empty }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(maxBytes)
        if truncated { try? handle.seek(toOffset: size - UInt64(maxBytes)) } else { try? handle.seek(toOffset: 0) }
        guard let data = try? handle.readToEnd() else { return .empty }
        // Lossy decode: a byte-aligned tail can start mid-character; we drop the first
        // (partial) line below when truncated, so a stray replacement char never matters.
        let text = String(decoding: data, as: UTF8.self)

        var hourCounts = Array(repeating: 0, count: 24)
        var weekdayHourCounts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var total = 0
        var dayKeys = Set<Int>()
        var first: Date?
        var last: Date?

        var lines = Array(text.split(separator: "\n"))
        if truncated, !lines.isEmpty { lines.removeFirst() }   // drop the partial first line
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ms = obj["timestamp"] as? Double else { continue }
            let date = Date(timeIntervalSince1970: ms / 1000)
            let comps = calendar.dateComponents([.hour, .weekday], from: date)
            guard let hour = comps.hour, let weekday = comps.weekday else { continue }

            hourCounts[hour] += 1
            weekdayHourCounts[weekday - 1][hour] += 1   // weekday is 1-based, 1 = Sunday
            total += 1
            if let dayOrdinal = calendar.ordinality(of: .day, in: .era, for: date) {
                dayKeys.insert(dayOrdinal)
            }
            if first == nil || date < first! { first = date }
            if last == nil || date > last! { last = date }
        }

        return ActivityProfile(
            hourCounts: hourCounts,
            weekdayHourCounts: weekdayHourCounts,
            totalPrompts: total,
            distinctDays: dayKeys.count,
            firstPrompt: first,
            lastPrompt: last
        )
    }
}
