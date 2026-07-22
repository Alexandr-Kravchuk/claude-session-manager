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

    /// Ranges zoomed in enough for 5h-session detail to read: work-hour bands, the
    /// over-rate highlight, and per-session ideal-pace lines. On 14d/30d a 5h window is a
    /// few percent of the chart width, so those marks collapse into noise and are hidden.
    private var isShortRange: Bool {
        [.sixHours, .twelveHours, .oneDay, .sevenDays].contains(range)
    }

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
        GeometryReader { geo in
            usageTabContent(chartHeight: min(580, max(290, geo.size.height - 310)))
        }
    }

    private func usageTabContent(chartHeight: CGFloat) -> some View {
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
                        burnChart.frame(height: chartHeight)
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

            if range == .sevenDays {
                ForEach(dayLabelTicks, id: \.self) { day in
                    RuleMark(x: .value("Day", day))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }

            // Dashed "ideal pace" reference per window — the straight line from 0 % at the
            // window's start to 100 % at its reset. Drawn dimmed and under the real series.
            ForEach(Array(idealPaceLines.enumerated()), id: \.offset) { index, line in
                ForEach([line.start, line.end], id: \.0) { point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("Used %", point.1),
                        series: .value("Window", "ideal-\(index)")
                    )
                    .foregroundStyle(color(forSeries: line.series).opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
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

            // Thick red overlay on the Session (5h) line where it climbed faster than normal,
            // drawn after the series lines so it sits on top. Each segment gets its own series
            // id so contiguous segments don't get bridged across gaps.
            ForEach(Array(overRateSegments.enumerated()), id: \.offset) { index, segment in
                ForEach([segment.start, segment.end], id: \.date) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Used %", sample.session),
                        series: .value("Window", "over-rate-\(index)")
                    )
                    .foregroundStyle(overRateTint)
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                }
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
                if isShortRange {
                    legendItem(
                        Capsule().fill(overRateTint).frame(width: 18, height: 4),
                        "Faster than normal (>20 %/h)"
                    )
                }
                legendItem(
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(Color.secondary).frame(width: 4, height: 2)
                        }
                    },
                    "Ideal pace (100 % at reset)"
                )
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
        guard isShortRange else { return [] }
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

    /// Stretches where the 5h session line climbed faster than "normal", highlighted on the
    /// line itself. Hidden on 14d/30d, where any active climb exceeds the threshold and the
    /// highlight would swallow the whole line.
    private var overRateSegments: [(start: UsageSample, end: UsageSample)] {
        isShortRange ? fastBurnSegments(in: filteredSamples) : []
    }

    /// "Ideal pace" segments for every quota window visible in the sampled history — one
    /// straight line per window, 0 % at its start rising to 100 % at its reset. 5h session
    /// windows open on activity, so their starts come from the recorded samples; 7d windows
    /// reset on a fixed schedule, so past ones sit at exact multiples of the duration back
    /// from the known reset. All segments are clipped to the sampled X-domain so a reset
    /// hours or days away never stretches the chart into the future.
    private var idealPaceLines: [(series: String, start: (Date, Double), end: (Date, Double))] {
        let dates = filteredBurnSeries.map(\.date)
        guard let lo = dates.min(), let hi = dates.max(), hi > lo else { return [] }
        var lines: [(series: String, start: (Date, Double), end: (Date, Double))] = []

        func append(_ series: String, windowStart: Date, duration: TimeInterval) {
            let x0 = max(windowStart, lo)
            let x1 = min(windowStart.addingTimeInterval(duration), hi)
            guard x1 > x0 else { return }
            func percent(_ d: Date) -> Double { d.timeIntervalSince(windowStart) / duration * 100 }
            lines.append((series, (x0, percent(x0)), (x1, percent(x1))))
        }

        // Per-session ideal lines only where a 5h window is wide enough to read; on 14d/30d
        // they would be dozens of near-vertical dashes across the whole chart.
        if isShortRange {
            let sessionDuration: TimeInterval = 5 * 3600
            let sessionResets = snapshot?.session.resetsAt
            for window in sessionWindows(in: filteredSamples, duration: sessionDuration, lastResetsAt: sessionResets) {
                append("Session (5h)", windowStart: window.start, duration: sessionDuration)
            }
        }

        func addPeriodic(_ series: String, _ window: RateWindow?) {
            guard let window, let resetsAt = window.resetsAt, window.windowDuration > 0 else { return }
            var end = resetsAt
            while end > lo {
                append(series, windowStart: end.addingTimeInterval(-window.windowDuration), duration: window.windowDuration)
                end = end.addingTimeInterval(-window.windowDuration)
            }
        }
        addPeriodic("Weekly", snapshot?.weekly)
        if let scoped = snapshot?.scopedWeekly {
            addPeriodic(snapshot?.scopedModelName.map { "\($0) (7d)" } ?? "Model (7d)", scoped)
        }
        return lines
    }

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

    /// Samples inside the selected range, decimated on 14d/30d — at those widths one point
    /// per ~4 min is thousands of marks Swift Charts visibly chokes on, while the curve's
    /// shape survives a much coarser grid. Samples adjacent to a session reset (the drop and
    /// the peak before it) and the latest sample are always kept so resets stay sharp.
    private var filteredSamples: [UsageSample] {
        let cutoff = Date().addingTimeInterval(-range.interval)
        let recent = samples.filter { $0.date >= cutoff }
        guard let minGap = range.decimationGap else { return recent }
        var kept: [UsageSample] = []
        for (i, sample) in recent.enumerated() {
            let isLast = i == recent.count - 1
            let dropsNext = !isLast && recent[i + 1].session < sample.session
            let droppedFromPrev = i > 0 && sample.session < recent[i - 1].session
            if let last = kept.last, !isLast, !dropsNext, !droppedFromPrev,
               sample.date.timeIntervalSince(last.date) < minGap { continue }
            kept.append(sample)
        }
        return kept
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
        // A series with a single in-range point can't draw a line — it would only add a
        // stray legend entry and a lone dot (e.g. legacy "Sonnet (7d)" at the edge of 30d).
        let counts = Dictionary(grouping: points, by: \.series).mapValues(\.count)
        return points.filter { counts[$0.series, default: 0] >= 2 }
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

    /// Minimum spacing between charted samples, nil = draw every sample. Only the two
    /// widest ranges thin the data; see `filteredSamples` for the rationale.
    var decimationGap: TimeInterval? {
        switch self {
        case .fourteenDays: return 15 * 60
        case .thirtyDays: return 30 * 60
        default: return nil
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
/// segment (no segment spans a reset). `samples` is expected chronological (the history store is
/// append-only and keeps timestamps in place).
func fastBurnSegments(in samples: [UsageSample], ratePerHour: Double = 20) -> [(start: UsageSample, end: UsageSample)] {
    var segments: [(start: UsageSample, end: UsageSample)] = []
    for (a, b) in zip(samples, samples.dropFirst()) {
        let dtHours = (b.t - a.t) / 3600
        guard dtHours > 0 else { continue }
        let delta = b.session - a.session
        guard delta > 0 else { continue }           // reset or flat — not a segment
        if delta / dtHours > ratePerHour { segments.append((a, b)) }
    }
    return segments
}

/// Estimated span of every 5h session window visible in `samples`. A drop in the session
/// percent is a reset — the precisely observable END of a window — so completed windows
/// anchor there (midpoint of the two samples around the drop) and extend exactly `duration`
/// back. The still-open window at the tail has no drop yet: its end is the API-reported
/// `lastResetsAt` when available, otherwise its start is back-projected from the first
/// sample where the percent begins to climb. Flat tail runs with no reset date yield nothing.
func sessionWindows(
    in samples: [UsageSample],
    duration: TimeInterval = 5 * 3600,
    lastResetsAt: Date? = nil
) -> [(start: Date, end: Date)] {
    var windows: [(start: Date, end: Date)] = []
    var runStart = 0
    for i in samples.indices {
        let isTail = i == samples.count - 1
        let drops = !isTail && samples[i + 1].session < samples[i].session
        guard drops || isTail else { continue }
        if drops {
            let gap = samples[i + 1].date.timeIntervalSince(samples[i].date)
            let reset = samples[i].date.addingTimeInterval(gap / 2)
            windows.append((reset.addingTimeInterval(-duration), reset))
            runStart = i + 1
        } else if let reset = lastResetsAt {
            windows.append((reset.addingTimeInterval(-duration), reset))
        } else if let climb = (runStart..<i).first(where: { samples[$0 + 1].session > samples[$0].session }) {
            let anchor = samples[climb]
            let start = anchor.date.addingTimeInterval(-anchor.session / 100 * duration)
            windows.append((start, start.addingTimeInterval(duration)))
        }
    }
    return windows
}

#if DEBUG
/// Sanity-checks the slope/reset logic on synthetic samples; called once at launch in DEBUG.
func runFastBurnSegmentsSelfCheck() {
    func s(_ minutes: Double, _ pct: Double) -> UsageSample {
        UsageSample(t: minutes * 60, session: pct, weekly: nil, scoped: nil,
                    scopedModel: nil, sonnet: nil, opus: nil)
    }
    // 0→5 % in 4 min = 75 %/h (fires); then 5→1 % is a reset, so exactly one segment.
    assert(fastBurnSegments(in: [s(0, 0), s(4, 5), s(8, 1)]).count == 1)
    // 1 % in 4 min = 15 %/h — below the 20 %/h normal, so no segment.
    assert(fastBurnSegments(in: [s(0, 0), s(4, 1)]).isEmpty)

    // Reset at 5→1 (between minutes 4 and 8) ends a completed window anchored at the drop
    // midpoint (minute 6); the tail run has no reset date and no climb, so nothing more.
    let dur: TimeInterval = 300 * 60
    let completed = sessionWindows(in: [s(0, 0), s(4, 5), s(8, 1)], duration: dur)
    assert(completed.count == 1)
    assert(completed[0].end == Date(timeIntervalSince1970: 6 * 60))
    assert(completed[0].start == completed[0].end.addingTimeInterval(-dur))
    // With the API reset known, the open tail window anchors exactly there.
    let reset = Date(timeIntervalSince1970: 200 * 60)
    let open = sessionWindows(in: [s(0, 0), s(4, 5)], duration: dur, lastResetsAt: reset)
    assert(open.count == 1 && open[0].end == reset)
    // No reset date: the tail back-projects 1 % → 3 min before the climb sample.
    let projected = sessionWindows(in: [s(0, 1), s(4, 5)], duration: dur)
    assert(projected.count == 1)
    assert(projected[0].start == Date(timeIntervalSince1970: -3 * 60))
    // Flat run, no reset date — no window.
    assert(sessionWindows(in: [s(0, 3), s(4, 3)]).isEmpty)
}
#endif
