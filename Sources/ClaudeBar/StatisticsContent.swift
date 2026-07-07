import SwiftUI
import Charts

/// Pure presentation of the activity profile and recorded quota-burn samples. Takes its data
/// as plain values so it can be rendered without a live `UsageStore`.
struct StatisticsContent: View {
    let activity: ActivityProfile
    let samples: [UsageSample]

    private let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]   // Mon…Sun, mapped to (weekday-1) indices
    private let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                activitySection
                Divider()
                burnSection
            }
            .padding(24)
        }
        .frame(minWidth: 660, minHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("When you use Claude Code", systemImage: "clock.badge.checkmark")

            if !activitySummary.isEmpty {
                Text(activitySummary)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if activity.totalPrompts == 0 {
                emptyState("No prompt history found in ~/.claude/history.jsonl yet.")
            } else {
                hourlyChart
                Text("Prompts by hour of day · blue = your active hours, grey = rarely used")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                heatmap
                Text("Prompts by weekday × hour — darker means busier")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var activitySummary: String {
        guard activity.totalPrompts > 0 else { return "" }
        var parts = ["\(activity.totalPrompts) prompts over \(activity.distinctDays) day(s)."]
        if activity.hasEnoughData {
            if let dead = activity.deadRangeDescription {
                parts.append("You're rarely active \(dead) — ClaudeBar discounts limit resets that fall in this window.")
            } else {
                parts.append("Your activity is spread evenly enough that there's no clear off-hours window.")
            }
        } else {
            parts.append("Not enough history yet to detect your off-hours (need ~5 days and 40+ prompts).")
        }
        return parts.joined(separator: " ")
    }

    /// A plain-SwiftUI vertical histogram rather than a Swift Charts BarMark: bar widths on
    /// a quantitative axis render unreliably, and this matches the heatmap's primitives.
    private var hourlyChart: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = activity.hourCounts[hour]
                    // Height tracks intensity (relative to a typical busy hour, clamped), so a
                    // single outlier burst doesn't flatten every other bar to nothing.
                    let height = count > 0 ? max(3, CGFloat(min(1.0, activity.intensity(hour: hour))) * 130) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(activity.isActive(hour: hour)
                            ? Color.accentColor
                            : Color.secondary.opacity(0.35))
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                        .help("\(hour):00 — \(count) prompt(s)")
                }
            }
            .frame(height: 130, alignment: .bottom)
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var heatmap: some View {
        let maxCell = max(1, activity.weekdayHourCounts.flatMap { $0 }.max() ?? 0)
        return VStack(spacing: 3) {
            ForEach(Array(weekdayOrder.enumerated()), id: \.offset) { row, dayIndex in
                HStack(spacing: 3) {
                    Text(weekdayNames[row])
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { hour in
                        let count = activity.weekdayHourCounts[dayIndex][hour]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cellColor(count: count, max: maxCell))
                            .frame(height: 16)
                            .frame(maxWidth: .infinity)
                            .help("\(weekdayNames[row]) \(hour):00 — \(count) prompt(s)")
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 30)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func cellColor(count: Int, max: Int) -> Color {
        guard count > 0 else { return Color.secondary.opacity(0.08) }
        let intensity = Double(count) / Double(max)
        return Color.accentColor.opacity(0.18 + 0.82 * intensity)
    }

    // MARK: - Quota burn

    private var burnSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Quota burn over time", systemImage: "chart.xyaxis.line")

            if burnSeries.count < 2 {
                emptyState("Collecting data — \(samples.count) sample(s) so far. This chart fills in as ClaudeBar keeps running (no retroactive history).")
            } else {
                burnChart
                Text("Percent of each window used, sampled while ClaudeBar runs. The saw-tooth is each window resetting.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Flatten samples into chartable (date, series, percent) points, dropping windows that
    /// never appeared so the legend only lists series we actually have data for.
    private var burnSeries: [BurnPoint] {
        var points: [BurnPoint] = []
        for sample in samples {
            points.append(BurnPoint(date: sample.date, series: "Session (5h)", percent: sample.session))
            if let weekly = sample.weekly { points.append(BurnPoint(date: sample.date, series: "Weekly", percent: weekly)) }
            if let opus = sample.opus { points.append(BurnPoint(date: sample.date, series: "Opus (7d)", percent: opus)) }
            if let sonnet = sample.sonnet { points.append(BurnPoint(date: sample.date, series: "Sonnet (7d)", percent: sonnet)) }
            if let scoped = sample.scoped {
                let label = sample.scopedModel.map { "\($0) (7d)" } ?? "Model (7d)"
                points.append(BurnPoint(date: sample.date, series: label, percent: scoped))
            }
        }
        return points
    }

    private var burnChart: some View {
        Chart(burnSeries) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Used %", point.percent),
                series: .value("Window", point.series)
            )
            .foregroundStyle(by: .value("Window", point.series))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { _ in
                AxisGridLine()
                AxisValueLabel().font(.system(size: 9))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month().day(), centered: false).font(.system(size: 9))
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 200)
    }

    // MARK: - Shared

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
                .font(.system(size: 14))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

struct BurnPoint: Identifiable {
    let id = UUID()
    let date: Date
    let series: String
    let percent: Double
}
