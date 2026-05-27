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

    var statusSymbol: String {
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

    func recommend() -> Recommendation {
        let sessionRec = evalSession(snapshot.session)
        let weeklyRec = snapshot.weekly.map { evalWeekly($0, label: "Weekly") }
        let modelRec = evalModels()

        let urgency = [sessionRec.urgency, weeklyRec?.urgency, modelRec?.urgency]
            .compactMap { $0 }
            .max() ?? .low

        let headline: String = switch urgency {
        case .low: "Ready — run large tasks"
        case .medium: "Caution — some limits"
        case .high: "Wait or switch model"
        case .critical: "Stop — limit exhausted"
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

        if let projected = w.projectedUsageAtReset, projected >= 100 {
            if let rate = w.burnRatePerHour, rate > 0 {
                let hoursLeft = (100 - w.usedPercent) / rate
                return WindowEval(urgency: .high, line: "Session exhausts in \(formatDuration(hoursLeft * 3600))")
            }
            return WindowEval(urgency: .high, line: "Session will exhaust before reset")
        }

        if remaining < 10 {
            if resetIn < 15 * 60 {
                return WindowEval(urgency: .medium, line: "Session nearly empty, resets in \(formatDuration(resetIn))")
            }
            return WindowEval(urgency: .critical, line: "Session exhausted. Resets in \(formatDuration(resetIn))")
        }

        if remaining < 25 {
            if resetIn < 30 * 60 {
                return WindowEval(urgency: .low, line: "\(pct(remaining)) left, resets in \(formatDuration(resetIn))")
            }
            return WindowEval(urgency: .medium, line: "Session: \(pct(remaining)) left (\(formatDuration(resetIn)) until reset)")
        }

        if resetIn < 20 * 60 {
            return WindowEval(urgency: .low, line: "Session resets in \(formatDuration(resetIn)) · \(pct(remaining)) left")
        }

        return WindowEval(urgency: .low, line: "Session: \(pct(remaining)) left · resets in \(formatDuration(resetIn))")
    }

    private func evalWeekly(_ w: RateWindow, label: String) -> WindowEval {
        let remaining = w.remainingPercent
        let resetIn = w.timeUntilReset ?? .infinity

        if let projected = w.projectedUsageAtReset {
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
