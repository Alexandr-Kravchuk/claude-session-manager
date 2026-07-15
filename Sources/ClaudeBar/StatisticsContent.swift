import SwiftUI
import Charts

/// Pure presentation of the activity profile and recorded quota-burn samples. Takes its data
/// as plain values so it remains independently previewable and testable.
struct StatisticsContent: View {
    let activity: ActivityProfile
    let samples: [UsageSample]
    let snapshot: UsageSnapshot?
    let lastUpdated: Date?

    @State private var tab: StatisticsTab = .usage
    @State private var range: HistoryRange = .fourteenDays

    private let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]
    private let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch tab {
                case .usage: usageTab
                case .activity: activityTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 570)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Statistics")
                    .font(.system(size: 22, weight: .bold))
                if let lastUpdated {
                    Text("Live usage updated \(lastUpdated, style: .relative) ago")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("Waiting for the first usage update")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Picker("Section", selection: $tab) {
                ForEach(StatisticsTab.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Usage

    private var usageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                currentUsageCards

                HStack(alignment: .firstTextBaseline) {
                    sectionHeader("Quota burn", systemImage: "chart.xyaxis.line")
                    Spacer()
                    Picker("History range", selection: $range) {
                        ForEach(HistoryRange.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                if filteredBurnSeries.count < 2 {
                    emptyState("Collecting history. The graph fills in while ClaudeBar runs.")
                } else {
                    burnChart
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Lines show percent used. Drops to zero are quota-window resets; dots are the latest recorded values.")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var currentUsageCards: some View {
        if let snapshot {
            HStack(spacing: 12) {
                usageCard(title: "Session", subtitle: "5 hours", window: snapshot.session, color: .blue)
                if let weekly = snapshot.weekly {
                    usageCard(title: "Weekly", subtitle: "7 days", window: weekly, color: .green)
                }
                if let scoped = snapshot.scopedWeekly {
                    usageCard(
                        title: snapshot.scopedModelName ?? "Model",
                        subtitle: "7 days",
                        window: scoped,
                        color: .purple
                    )
                }
            }
        } else {
            emptyState("Waiting for current quota data.")
        }
    }

    private func usageCard(title: String, subtitle: String, window: RateWindow, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }

            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .tint(color)

            HStack {
                Text("used")
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var burnChart: some View {
        Chart {
            ForEach(filteredBurnSeries) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Used %", point.percent),
                    series: .value("Window", point.series)
                )
                .foregroundStyle(by: .value("Window", point.series))
                .interpolationMethod(.linear)
            }

            ForEach(latestBurnPoints) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Used %", point.percent)
                )
                .foregroundStyle(by: .value("Window", point.series))
                .symbolSize(42)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text("\(percent)%") }
                }
                .font(.system(size: 10))
            }
        }
        .chartXAxis {
            let axis = xAxisStyle
            AxisMarks(values: .stride(by: axis.unit, count: axis.count)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        VStack(spacing: 1) {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                            if axis.showTime {
                                Text(date, format: .dateTime.hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 10))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 16)
        .frame(height: 290)
    }

    /// The recorded window is often far shorter than the selected range (there is no
    /// retroactive data), so Charts fits the X domain to the actual samples. Pick a tick
    /// stride from that real span — otherwise a ~1-day span rounds every automatic tick to
    /// the same date and the axis prints "Jul 14 · Jul 14 · Jul 15 · Jul 15". Short spans
    /// also show the time, so ticks within one day stay distinct.
    private var xAxisStyle: (unit: Calendar.Component, count: Int, showTime: Bool) {
        let dates = filteredBurnSeries.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return (.day, 1, false) }
        switch hi.timeIntervalSince(lo) {
        case ..<(36 * 3600):   return (.hour, 6, true)    // < 1.5 days
        case ..<(3 * 86400):   return (.hour, 12, true)   // < 3 days
        case ..<(9 * 86400):   return (.day, 1, false)
        default:               return (.day, 3, false)
        }
    }

    private var filteredSamples: [UsageSample] {
        let cutoff = Date().addingTimeInterval(-range.interval)
        return samples.filter { $0.date >= cutoff }
    }

    private var filteredBurnSeries: [BurnPoint] {
        var points: [BurnPoint] = []
        for sample in filteredSamples {
            points.append(BurnPoint(date: sample.date, series: "Session (5h)", percent: sample.session))
            if let weekly = sample.weekly {
                points.append(BurnPoint(date: sample.date, series: "Weekly", percent: weekly))
            }
            if let opus = sample.opus {
                points.append(BurnPoint(date: sample.date, series: "Opus (7d)", percent: opus))
            }
            if let sonnet = sample.sonnet {
                points.append(BurnPoint(date: sample.date, series: "Sonnet (7d)", percent: sonnet))
            }
            if let scoped = sample.scoped {
                let label = sample.scopedModel.map { "\($0) (7d)" } ?? "Model (7d)"
                points.append(BurnPoint(date: sample.date, series: label, percent: scoped))
            }
        }
        return points
    }

    private var latestBurnPoints: [BurnPoint] {
        Dictionary(grouping: filteredBurnSeries, by: \.series)
            .compactMap { $0.value.max { $0.date < $1.date } }
    }

    // MARK: - Activity

    private var activityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("When you use Claude Code", systemImage: "clock.badge.checkmark")
                    Text(activitySummary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if activity.totalPrompts == 0 {
                    emptyState("No prompt history found in ~/.claude/history.jsonl yet.")
                } else {
                    chartCard(title: "Prompts by hour", caption: "Blue marks your active hours; grey marks rarely used hours.") {
                        hourlyChart
                    }
                    chartCard(title: "Weekly rhythm", caption: "Darker cells mean more prompts in that weekday and hour.") {
                        heatmap
                    }
                }
            }
            .padding(24)
        }
    }

    private var activitySummary: String {
        guard activity.totalPrompts > 0 else { return "No activity recorded yet." }
        var parts = ["\(activity.totalPrompts) prompts across \(activity.distinctDays) active day(s)."]
        if activity.hasEnoughData {
            if let dead = activity.deadRangeDescription {
                parts.append("You are rarely active \(dead); quota forecasts discount resets in this window.")
            } else {
                parts.append("Your activity is spread fairly evenly through the day.")
            }
        } else {
            parts.append("About 5 days and 40 prompts are needed to detect off-hours reliably.")
        }
        return parts.joined(separator: " ")
    }

    private func chartCard<Content: View>(
        title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
            Text(caption).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private var hourlyChart: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = activity.hourCounts[hour]
                    let height = count > 0 ? max(4, CGFloat(min(1.0, activity.intensity(hour: hour))) * 150) : 0
                    RoundedRectangle(cornerRadius: 3)
                        .fill(activity.isActive(hour: hour) ? Color.accentColor : Color.secondary.opacity(0.32))
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                        .help("\(hour):00 — \(count) prompt(s)")
                }
            }
            .frame(height: 150, alignment: .bottom)

            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var heatmap: some View {
        let maxCell = max(1, activity.weekdayHourCounts.flatMap { $0 }.max() ?? 0)
        return VStack(spacing: 5) {
            ForEach(Array(weekdayOrder.enumerated()), id: \.offset) { row, dayIndex in
                HStack(spacing: 4) {
                    Text(weekdayNames[row])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { hour in
                        let count = activity.weekdayHourCounts[dayIndex][hour]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cellColor(count: count, max: maxCell))
                            .frame(height: 22)
                            .frame(maxWidth: .infinity)
                            .help("\(weekdayNames[row]) \(hour):00 — \(count) prompt(s)")
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer().frame(width: 34)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.system(size: 9))
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

    // MARK: - Shared

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
                .font(.system(size: 16))
            Text(title).font(.system(size: 17, weight: .semibold))
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }
}

private enum StatisticsTab: String, CaseIterable, Identifiable {
    case usage
    case activity

    var id: Self { self }
    var title: String { self == .usage ? "Usage" : "Activity" }
    var icon: String { self == .usage ? "chart.xyaxis.line" : "clock" }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case sevenDays
    case fourteenDays
    case thirtyDays

    var id: Self { self }
    var title: String {
        switch self {
        case .sevenDays: return "7d"
        case .fourteenDays: return "14d"
        case .thirtyDays: return "30d"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .sevenDays: return 7 * 86400
        case .fourteenDays: return 14 * 86400
        case .thirtyDays: return 30 * 86400
        }
    }
}

struct BurnPoint: Identifiable {
    let id = UUID()
    let date: Date
    let series: String
    let percent: Double
}
