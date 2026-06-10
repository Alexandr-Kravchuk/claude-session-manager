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
                headline = "Model limits low"
            }
        case .high:
            let onlyModelsCausedHigh = modelRec?.urgency == .high
                && sessionRec.urgency < .high
                && (weeklyRec?.urgency ?? .low) < .high
            if onlyModelsCausedHigh {
                headline = "Switch model"
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

    /// Which model to push the spare weekly capacity into: the one with the larger
    /// projected leftover, as long as its own window isn't already tight.
    private func headroomModelLine() -> String? {
        let candidates: [(String, RateWindow)] = [
            ("Opus", snapshot.opusWeekly),
            ("Sonnet", snapshot.sonnetWeekly),
        ].compactMap { name, window in window.map { (name, $0) } }
            .filter { _, window in
                let tier = window.paceTier(kind: .weekly)
                return tier != .hot && tier != .runsOut
            }
        guard let best = candidates.max(by: {
            ($0.1.projectedLeftAtReset ?? $0.1.remainingPercent)
                < ($1.1.projectedLeftAtReset ?? $1.1.remainingPercent)
        }) else { return nil }
        return "Run heavy \(best.0) tasks — this capacity expires"
    }

    private func evalModels() -> WindowEval? {
        let opus = snapshot.opusWeekly
        let sonnet = snapshot.sonnetWeekly

        if let o = opus, o.remainingPercent < 20 {
            if let s = sonnet, s.remainingPercent > 40 {
                return WindowEval(urgency: .high, line: "Opus nearly exhausted (\(pct(o.remainingPercent))) — switch to Sonnet")
            }
            return WindowEval(urgency: .medium, line: "Opus weekly: \(pct(o.remainingPercent)) left")
        }

        if let s = sonnet, s.remainingPercent < 20 {
            if let o = opus, o.remainingPercent > 40 {
                return WindowEval(urgency: .medium, line: "Sonnet nearly exhausted (\(pct(s.remainingPercent))) — try Opus")
            }
            return WindowEval(urgency: .high, line: "Sonnet weekly: \(pct(s.remainingPercent)) left")
        }

        return nil
    }
}

private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
