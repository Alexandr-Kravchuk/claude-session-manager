import Foundation

enum Urgency: Int, Comparable {
    case low = 0, medium = 1, high = 2, critical = 3
    static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Recommendation {
    let urgency: Urgency
    let headline: String
    let sessionLine: String
    let weeklyLine: String?
    let modelLine: String?
    /// Weekly quota is pacing so low that a large share will expire unused.
    var isHeadroom: Bool = false

    var statusSymbol: String {
        if isHeadroom { return "arrow.up.circle.fill" }
        switch urgency {
        case .low: return "checkmark.circle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        }
    }
}

struct Recommender {
    let snapshot: UsageSnapshot
    /// New pace UI: enables the headroom headline and clock-framed exhaust wording.
    var newPaceUI: Bool = false
    /// When the user actually works. Lets a session that would only run out (or reset)
    /// during their off-hours stop shouting — you can't feel a wall you hit while asleep.
    var activity: ActivityProfile = .empty

    func recommend() -> Recommendation {
        let sessionRec = evalSession(snapshot.session)
        let weeklyRec = snapshot.weekly.map { evalWeekly($0, label: "Weekly") }
        let modelRec = evalModels()

        let urgency = [sessionRec.urgency, weeklyRec?.urgency, modelRec?.urgency]
            .compactMap { $0 }
            .max() ?? .low

        if newPaceUI, urgency == .low, let weekly = snapshot.weekly,
           weekly.paceTier(kind: .weekly) == .idle,
           let left = weekly.projectedLeftAtReset {
            return Recommendation(
                urgency: .low,
                headline: "Headroom — ~\(Int(left.rounded()))% of weekly will go unused",
                sessionLine: sessionRec.line,
                weeklyLine: weeklyRec?.line,
                modelLine: headroomModelLine(),
                isHeadroom: true
            )
        }

        // A high session pace that only bites during the user's off-hours was downgraded to
        // .low in evalSession; surface its calm explanation instead of the generic "Ready".
        if urgency == .low, let reason = sessionRec.softenedReason {
            return Recommendation(
                urgency: .low,
                headline: reason,
                sessionLine: sessionRec.line,
                weeklyLine: weeklyRec?.line,
                modelLine: modelRec?.line
            )
        }

        let headline: String
        switch urgency {
        case .low:
            headline = "Ready — run large tasks"
        case .medium:
            if sessionRec.urgency == .medium {
                if let wait = snapshot.session.waitToReachProjected(80) {
                    headline = "Ease off for \(formatDuration(wait))"
                } else {
                    headline = "Session running low"
                }
            } else if weeklyRec?.urgency == .medium {
                if let weekly = snapshot.weekly, let wait = weekly.waitToReachProjected(80) {
                    headline = "Ease off for \(formatDuration(wait))"
                } else {
                    headline = "Weekly running low"
                }
            } else {
                headline = "\(scopedModelName) limit low"
            }
        case .high:
            let onlyModelsCausedHigh = modelRec?.urgency == .high
                && sessionRec.urgency < .high
                && (weeklyRec?.urgency ?? .low) < .high
            if onlyModelsCausedHigh {
                headline = "\(scopedModelName) weekly running low"
            } else if sessionRec.urgency == .high {
                if newPaceUI, snapshot.session.remainingPercent < 5,
                   let resetIn = snapshot.session.timeUntilReset {
                    // Already exhausted — a future-tense "runs out in…" would be a lie.
                    headline = "Session exhausted — resets in \(formatDuration(resetIn))"
                } else if newPaceUI, let runOut = snapshot.session.timeToExhaustion,
                   let resetIn = snapshot.session.timeUntilReset, resetIn > runOut {
                    headline = "Session runs out \(formatDuration(resetIn - runOut)) before reset — ease off"
                } else if let wait = snapshot.session.waitToStabilize {
                    headline = "Wait \(formatDuration(wait)) — session will exhaust"
                } else {
                    headline = "Wait — session will exhaust"
                }
            } else {
                headline = "Slow down — weekly pace too high"
            }
        case .critical:
            headline = "Stop — limit exhausted"
        }

        return Recommendation(
            urgency: urgency,
            headline: headline,
            sessionLine: sessionRec.line,
            weeklyLine: weeklyRec?.line,
            modelLine: modelRec?.line
        )
    }

    private struct WindowEval {
        let urgency: Urgency
        let line: String
        /// Set when off-hours discounting downgraded this window: the calm headline to show
        /// in place of the alarmist one the raw pace would have produced.
        var softenedReason: String? = nil
    }

    private func evalSession(_ w: RateWindow) -> WindowEval {
        let remaining = w.remainingPercent
        let resetIn = w.timeUntilReset ?? .infinity
        let tier = w.paceTier(kind: .session)

        // Will exhaust before reset? — but only once the forecast is trustworthy.
        // While the tier is .early the projection is noise on a tiny denominator,
        // and a confident "runs out" headline would contradict the "Early" chip.
        if tier != .early, let projected = w.projectedUsageAtReset, projected >= 100 {
            if let rate = w.burnRatePerHour, rate > 0 {
                let hoursLeft = (100 - w.usedPercent) / rate
                // If the wall lands in your off-hours, you'll have stopped before you hit
                // it — don't raise the alarm, just note it.
                let exhaustAt = Date().addingTimeInterval(hoursLeft * 3600)
                if remaining >= 10, activity.isDeadTime(exhaustAt) {
                    return WindowEval(
                        urgency: .low,
                        line: "Session pace high, but runs out during your off-hours",
                        softenedReason: "Pace high — but you usually stop before it runs out"
                    )
                }
                return WindowEval(urgency: .high, line: "Session exhausts in \(formatDuration(hoursLeft * 3600))")
            }
            return WindowEval(urgency: .high, line: "Session will exhaust before reset")
        }

        // Critically low in absolute terms
        if remaining < 10 {
            if resetIn < 15 * 60 {
                return WindowEval(urgency: .medium, line: "Session nearly empty, resets in \(formatDuration(resetIn))")
            }
            return WindowEval(urgency: .critical, line: "Session exhausted. Resets in \(formatDuration(resetIn))")
        }

        // Pace is high but won't exhaust (projected 85–99%)
        if tier != .early, let projected = w.projectedUsageAtReset, projected >= 85 {
            // The window resets while you're off the clock, so "ease off to pace it" is
            // moot — you'll stop long before the high pace would cost you anything.
            if let resetsAt = w.resetsAt, activity.isDeadTime(resetsAt) {
                return WindowEval(
                    urgency: .low,
                    line: "Session pace high, but resets during your off-hours",
                    softenedReason: "Pace high — but it resets while you're away"
                )
            }
            if let wait = w.waitToReachProjected(80) {
                return WindowEval(urgency: .medium, line: "Session pace high — ease off for \(formatDuration(wait))")
            }
            return WindowEval(urgency: .medium, line: "Session pace high — \(Int(projected.rounded()))% projected")
        }

        // Running low but pace is fine
        if remaining < 25 {
            if resetIn < 30 * 60 {
                return WindowEval(urgency: .low, line: "\(pct(remaining)) left, resets in \(formatDuration(resetIn))")
            }
            // Projected unknown — be cautious
            if w.projectedUsageAtReset == nil {
                return WindowEval(urgency: .medium, line: "Session: \(pct(remaining)) left (\(formatDuration(resetIn)) until reset)")
            }
            return WindowEval(urgency: .low, line: "\(pct(remaining)) left · resets in \(formatDuration(resetIn))")
        }

        if resetIn < 20 * 60 {
            return WindowEval(urgency: .low, line: "Session resets in \(formatDuration(resetIn)) · \(pct(remaining)) left")
        }

        return WindowEval(urgency: .low, line: "Session: \(pct(remaining)) left · resets in \(formatDuration(resetIn))")
    }

    private func evalWeekly(_ w: RateWindow, label: String) -> WindowEval {
        let remaining = w.remainingPercent
        let resetIn = w.timeUntilReset ?? .infinity
        let tier = w.paceTier(kind: .weekly)

        if tier != .early, let projected = w.projectedUsageAtReset {
            if projected >= 100 {
                return WindowEval(urgency: .high, line: "\(label): limit will exhaust before reset (pace too high)")
            }
            return WindowEval(urgency: .low, line: "\(label): \(pct(remaining)) left · resets in \(formatDuration(resetIn))")
        }

        // No projection yet — fall back to raw remaining %
        if remaining < 10 {
            return WindowEval(urgency: .critical, line: "\(label): \(pct(remaining)) left, resets in \(formatDuration(resetIn))")
        }
        if remaining < 25 {
            return WindowEval(urgency: .medium, line: "\(label): \(pct(remaining)) left")
        }
        return WindowEval(urgency: .low, line: "\(label): \(pct(remaining)) left · resets in \(formatDuration(resetIn))")
    }

    /// Nudge to spend the per-model weekly capacity that would otherwise expire — only while
    /// that scoped window isn't itself already tight.
    private func headroomModelLine() -> String? {
        guard let window = snapshot.scopedWeekly else { return nil }
        let tier = window.paceTier(kind: .weekly)
        guard tier != .hot, tier != .runsOut else { return nil }
        return "Run heavy \(scopedModelName) tasks — this capacity expires"
    }

    /// The endpoint now reports a single per-model weekly cap (`weekly_scoped`) scoped to
    /// whichever model you're metered against, so there's no second window to switch to —
    /// just surface it when it's running low.
    private func evalModels() -> WindowEval? {
        guard let w = snapshot.scopedWeekly else { return nil }
        let remaining = w.remainingPercent
        if remaining < 10 {
            return WindowEval(urgency: .high, line: "\(scopedModelName) weekly: \(pct(remaining)) left")
        }
        if remaining < 20 {
            return WindowEval(urgency: .medium, line: "\(scopedModelName) weekly: \(pct(remaining)) left")
        }
        return nil
    }

    /// Name of the scoped model for user-facing lines, with a neutral fallback.
    private var scopedModelName: String { snapshot.scopedModelName ?? "Model" }
}

private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
