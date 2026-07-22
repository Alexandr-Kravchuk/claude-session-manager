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
    @AppStorage("com.claudebar.historyRange") private var range: HistoryRange = .oneDay

    private let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]
    private let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    // Background band tints. Kept subtle on-chart (they cover a large area); the legend
    // swatches use a stronger opacity so a small chip stays legible.
    private let workHourTint = Color.secondary
    private let overRateTint = Color.red

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
                    .frame(width: 280)
                }

                if filteredBurnSeries.count < 2 {
                    emptyState("Collecting history. The graph fills in while ClaudeBar runs.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        burnChart
                        chartLegend
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Lines show percent used; drops to zero are quota-window resets; dots are the latest recorded values.")
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
            ForEach(workHourBands, id: \.start) { band in
                RectangleMark(
                    xStart: .value("Start", band.start),
                    xEnd: .value("End", band.end),
                    yStart: .value("Low", 0),
                    yEnd: .value("High", 100)
                )
                .foregroundStyle(workHourTint.opacity(0.09))
            }

            ForEach(overRateBands, id: \.start) { band in
                RectangleMark(
                    xStart: .value("Start", band.start),
                    xEnd: .value("End", band.end),
                    yStart: .value("Low", 0),
                    yEnd: .value("High", 100)
                )
                .foregroundStyle(overRateTint.opacity(0.12))
            }

            if range == .sevenDays {
                ForEach(dayLabelTicks, id: \.self) { day in
                    RuleMark(x: .value("Day", day))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }

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
            AxisMarks(values: xAxisTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self), shouldLabelTick(date) {
                        if range == .sevenDays {
                            // 7d shows day labels on their own pass below (at noon), so the
                            // 9:00/18:00 hour ticks only need the time, not a repeated date.
                            Text(date, format: .dateTime.hour().minute())
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
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
            if range == .sevenDays {
                AxisMarks(values: dayLabelTicks) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 10))
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)   // replaced by the unified custom legend below the chart
        .chartForegroundStyleScale(domain: seriesLegendOrder, range: seriesLegendOrder.map(color(forSeries:)))
        .frame(height: 290)
    }

    /// One legend for everything the chart draws — line series and background bands — so every
    /// color is spelled out in a single place under the chart. Band swatches only appear when
    /// that band can be drawn for the current range.
    private var chartLegend: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
                ForEach(seriesLegendOrder, id: \.self) { series in
                    legendItem(Circle().fill(color(forSeries: series)).frame(width: 9, height: 9), series)
                }
            }
            HStack(spacing: 16) {
                if !workHourBands.isEmpty {
                    legendItem(bandSwatch(workHourTint.opacity(0.18)), "Work hours (9:00–18:00)")
                }
                legendItem(bandSwatch(overRateTint.opacity(0.25)), "Faster than normal (>20 %/h)")
            }
        }
    }

    private func legendItem(_ swatch: some View, _ label: String) -> some View {
        HStack(spacing: 6) {
            swatch
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func bandSwatch(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fill)
            .frame(width: 18, height: 11)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
    }

    /// Grey bands over 9:00–18:00 each day, so the burn curve reads against work hours at a
    /// glance. Only the intraday ranges (6h/12h/1d) and 7d are zoomed in enough for day-by-day
    /// banding to mean anything.
    private var workHourBands: [(start: Date, end: Date)] {
        guard [.sixHours, .twelveHours, .oneDay, .sevenDays].contains(range) else { return [] }
        let dates = filteredBurnSeries.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return [] }
        let calendar = Calendar.current
        var bands: [(start: Date, end: Date)] = []
        var day = calendar.startOfDay(for: lo)
        while day <= hi {
            if let start = calendar.date(byAdding: .hour, value: 9, to: day),
               let end = calendar.date(byAdding: .hour, value: 18, to: day),
               start < hi, end > lo {
                bands.append((max(start, lo), min(end, hi)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return bands
    }

    /// Red bands over stretches where the 5h session line climbed faster than "normal".
    private var overRateBands: [(start: Date, end: Date)] { fastBurnBands(in: filteredSamples) }

    /// Ticks anchored at midnight and stepped by `xAxisStyle`, instead of Charts' automatic
    /// `.stride`, which anchors wherever the data happens to start — an arbitrary offset that
    /// would just as often miss 9:00/18:00 as hit them. Anchoring at midnight with a stride
    /// that divides both 9 and 24 (3h, used for 1d/7d) makes those work-hour band edges land
    /// exactly on a tick every time, and keeps every other tick evenly spaced around them.
    private var xAxisTicks: [Date] {
        let dates = filteredBurnSeries.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return [] }
        let calendar = Calendar.current
        let axis = xAxisStyle
        var tick = calendar.startOfDay(for: lo)
        var ticks: [Date] = []
        while tick <= hi {
            if tick >= lo { ticks.append(tick) }
            guard let next = calendar.date(byAdding: axis.unit, value: axis.count, to: tick) else { break }
            tick = next
        }
        return ticks
    }

    /// 7d's day labels, kept as their own axis pass at midnight — 2 ticks (6h) clear of the
    /// previous day's 18:00 and 3 ticks (9h) clear of this day's 9:00 — so they read as a
    /// separate "which day" row instead of colliding with the hour labels.
    private var dayLabelTicks: [Date] {
        xAxisTicks.filter { Calendar.current.component(.hour, from: $0) == 0 }
    }

    /// The recorded window is often far shorter than the selected range (there is no
    /// retroactive data), so Charts fits the X domain to the actual samples. Pick a tick
    /// stride from that real span — otherwise a ~1-day span rounds every automatic tick to
    /// the same date and the axis prints "Jul 14 · Jul 14 · Jul 15 · Jul 15". Short spans
    /// also show the time, so ticks within one day stay distinct.
    private var xAxisStyle: (unit: Calendar.Component, count: Int, showTime: Bool) {
        let dates = filteredBurnSeries.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return (.day, 1, false) }
        // 6h/12h/1d/7d use a fixed hour stride that divides 9 — so xAxisTicks' midnight anchor
        // puts 9:00 and 18:00 exactly on a tick (the work-hour band edges) regardless of span.
        if range == .sixHours { return (.hour, 1, true) }   // 6h span too short for a 3h stride
        if range == .twelveHours || range == .oneDay || range == .sevenDays { return (.hour, 3, true) }
        switch hi.timeIntervalSince(lo) {
        case ..<(36 * 3600):   return (.hour, 6, true)    // < 1.5 days
        case ..<(3 * 86400):   return (.hour, 12, true)   // < 3 days
        case ..<(9 * 86400):   return (.day, 1, false)
        default:               return (.day, 3, false)
        }
    }

    /// The 7d view's 3-hour gridlines are too dense to label every one (56 across the chart
    /// would overlap into an unreadable smear) — keep the fine gridlines for visual rhythm but
    /// only draw text at the work-hour band edges (9:00, 18:00), same as 1d where every tick
    /// (including those two) is labeled. 1d has few enough ticks (8) to label all of them.
    private func shouldLabelTick(_ date: Date) -> Bool {
        guard range == .sevenDays else { return true }
        let hour = Calendar.current.component(.hour, from: date)
        return hour == 9 || hour == 18
    }

    /// Fixed per-role colors so a series keeps its color across range filters. Without this,
    /// SwiftUI Charts assigns colors positionally from the default palette based on which
    /// series happen to be present — the scoped-model line would jump between orange and
    /// purple depending on whether legacy "Sonnet (7d)"/"Opus (7d)" samples fall in range.
    private func color(forSeries series: String) -> Color {
        switch series {
        case "Session (5h)": return .blue
        case "Weekly": return .green
        case "Sonnet (7d)": return .orange
        case "Opus (7d)": return .red
        default: return .purple // scoped-model line, e.g. "Fable (7d)" — matches the card above
        }
    }

    /// Stable legend order: fixed windows first, then any per-model series present.
    private var seriesLegendOrder: [String] {
        let fixed = ["Session (5h)", "Weekly", "Opus (7d)", "Sonnet (7d)"]
        let present = Set(filteredBurnSeries.map(\.series))
        var order = fixed.filter(present.contains)
        order.append(contentsOf: present.subtracting(fixed).sorted())
        return order
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
    case sixHours
    case twelveHours
    case oneDay
    case sevenDays
    case fourteenDays
    case thirtyDays

    var id: Self { self }
    var title: String {
        switch self {
        case .sixHours: return "6h"
        case .twelveHours: return "12h"
        case .oneDay: return "1d"
        case .sevenDays: return "7d"
        case .fourteenDays: return "14d"
        case .thirtyDays: return "30d"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .sixHours: return 6 * 3600
        case .twelveHours: return 12 * 3600
        case .oneDay: return 1 * 86400
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

/// Stretches where the 5h-session line rose faster than "normal" — normal being the pace that
/// spends the whole 5h window over exactly 5h of wall-clock (burn rate 1.0 = 20 %/h). Slope is
/// measured between consecutive samples; a drop in percent is a window reset, which breaks the
/// segment (no band spans a reset). `samples` is expected chronological (the history store is
/// append-only and keeps timestamps in place).
func fastBurnBands(in samples: [UsageSample], ratePerHour: Double = 20) -> [(start: Date, end: Date)] {
    var bands: [(start: Date, end: Date)] = []
    for (a, b) in zip(samples, samples.dropFirst()) {
        let dtHours = (b.t - a.t) / 3600
        guard dtHours > 0 else { continue }
        let delta = b.session - a.session
        guard delta > 0 else { continue }           // reset or flat — not a band
        if delta / dtHours > ratePerHour { bands.append((a.date, b.date)) }
    }
    return bands
}

#if DEBUG
/// Sanity-checks the slope/reset logic on synthetic samples; called once at launch in DEBUG.
func runFastBurnBandsSelfCheck() {
    func s(_ minutes: Double, _ pct: Double) -> UsageSample {
        UsageSample(t: minutes * 60, session: pct, weekly: nil, scoped: nil,
                    scopedModel: nil, sonnet: nil, opus: nil)
    }
    // 0→5 % in 4 min = 75 %/h (fires); then 5→1 % is a reset, so exactly one band.
    assert(fastBurnBands(in: [s(0, 0), s(4, 5), s(8, 1)]).count == 1)
    // 1 % in 4 min = 15 %/h — below the 20 %/h normal, so no band.
    assert(fastBurnBands(in: [s(0, 0), s(4, 1)]).isEmpty)
}
#endif
