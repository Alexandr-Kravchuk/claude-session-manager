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
            // The subtracted slab covers everything the chart shares the tab with: cards, section
            // header, scrubber, the three legend rows, the forecast summary and the footnote.
            // Understate it and the summary and footnote fall below the fold — which is exactly
            // where they must not be, being the written form of the projection.
            usageTabContent(chartHeight: min(580, max(290, geo.size.height - 430)))
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

                if chartSamples.count < 2 {
                    emptyState("Collecting history. The graph fills in while ClaudeBar runs.")
                } else {
                    BurnChartView(
                        samples: chartSamples,
                        snapshot: snapshot,
                        range: range,
                        chartHeight: chartHeight
                    )
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Lines show percent used; drops to zero are quota-window resets; dots are the latest recorded values. Scroll right past “now” for the projected run-out.")
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

    /// Chart-feeding samples: the full retained history (bounded to 30 days by the store),
    /// decimated to a per-range density so a single visible window draws a few hundred marks.
    /// Depends only on `samples` and `range` — never on the chart's scroll position — so panning
    /// through history never re-runs it; `BurnChartView` crops this to the visible window.
    /// A session reset (a drop, or the peak right before it) and the latest sample are always
    /// kept so resets stay sharp.
    private var chartSamples: [UsageSample] {
        // Aim for ~this many points across one visible window: smooth lines without flooding
        // Charts. Over the widest window (30d) this alone bounds the set; narrower windows lean
        // on BurnChartView's crop instead, so their minGap can stay below the ~4-min sampling.
        let minGap = range.interval / 400
        var kept: [UsageSample] = []
        for (i, sample) in samples.enumerated() {
            let isLast = i == samples.count - 1
            let dropsNext = !isLast && samples[i + 1].session < sample.session
            let droppedFromPrev = i > 0 && sample.session < samples[i - 1].session
            if let last = kept.last, !isLast, !dropsNext, !droppedFromPrev,
               sample.date.timeIntervalSince(last.date) < minGap { continue }
            kept.append(sample)
        }
        return kept
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

/// The quota-burn chart plus its own horizontal navigation. Takes the already-decimated,
/// full-history samples from the parent (so panning never re-runs that work) and owns only the
/// visible-window position. When more history is recorded than one selected range can show, a
/// slider scrubs through it at a fixed zoom — the visible window's width is always exactly
/// `range.interval`, so the scale is preserved as you move back in time. The chart renders only
/// the visible window (plus a small buffer for line continuity), so scrubbing stays cheap no
/// matter how much history has accumulated. Uses `chartXScale` (macOS 13+), not the scrollable-
/// axis APIs (macOS 14+), so a plain mouse gets an explicit, visible control rather than a
/// gesture-only scroll.
private struct BurnChartView: View {
    let samples: [UsageSample]        // decimated to the range's density; full retained history
    let snapshot: UsageSnapshot?
    let range: HistoryRange
    let chartHeight: CGFloat

    /// Left edge of the visible window; `nil` means "the latest window" (the default view).
    @State private var windowStart: Date?

    // Background band tints. Kept subtle on-chart (they cover a large area); the legend
    // swatches use a stronger opacity so a small chip stays legible.
    private let workHourTint = Color.secondary
    private let overRateTint = Color.red

    /// Ranges zoomed in enough for 5h-session detail to read: work-hour bands, the over-rate
    /// highlight, and per-session ideal-pace lines. On 14d/30d a 5h window is a few percent of
    /// the chart width, so those marks collapse into noise and are hidden.
    private var isShortRange: Bool {
        [.sixHours, .twelveHours, .oneDay, .sevenDays].contains(range)
    }

    private var dataStart: Date { samples.first?.date ?? Date() }
    private var dataEnd: Date { samples.last?.date ?? Date() }

    /// "Now": the boundary between recorded history and projection, and the anchor every
    /// forecast line starts from. The later of the last recorded sample and the live snapshot's
    /// fetch time, so the dashed projections begin where the solid lines stop rather than a
    /// step behind them.
    private var nowAnchor: Date { max(dataEnd, snapshot?.fetchedAt ?? dataEnd) }

    /// Right end of the scrollable timeline: the last reset any live forecast reaches, plus a
    /// sliver of padding so the final marks don't sit flush against the edge. Nothing past it
    /// is worth reaching — beyond the final reset there is neither a forecast nor an ideal-pace
    /// line left to draw (`periodicWindowStarts` walks backwards from the reset).
    private var timelineEnd: Date {
        guard let furthest = chartForecasts.map(\.resetsAt).max() else { return nowAnchor }
        return max(nowAnchor, furthest.addingTimeInterval(range.interval * 0.05))
    }

    /// The window the chart opens on: latest readings flush against the right edge. Scrolling
    /// right from here walks into the forecast.
    private var defaultStart: Date { nowAnchor.addingTimeInterval(-range.interval) }

    /// Scroll bounds. The lower one dips below `dataStart` when history is shorter than the
    /// selected range, so the window keeps its full width (and therefore its scale) instead of
    /// squeezing to fit whatever has been recorded so far.
    private var scrollMin: Date { min(dataStart, defaultStart) }
    private var scrollMax: Date { max(defaultStart, timelineEnd.addingTimeInterval(-range.interval)) }

    /// Only offer the scrubber when the window can actually move — and never hand `Slider(in:)`
    /// an empty range, which traps.
    private var canScroll: Bool { scrollMax > scrollMin }

    private func clamp(_ start: Date) -> Date { min(max(start, scrollMin), scrollMax) }

    private var effectiveStart: Date { clamp(windowStart ?? defaultStart) }

    // Visible X-domain: always exactly `range.interval` wide, so the scale is preserved wherever
    // the window sits — over history, over the forecast, or straddling both.
    private var domainStart: Date { effectiveStart }
    private var domainEnd: Date { effectiveStart.addingTimeInterval(range.interval) }

    /// Samples inside the visible window, plus a small buffer each side so lines reach the edges
    /// instead of stopping at the last in-window point. Cheap: a date filter over the decimated
    /// set, the only per-scroll work of consequence. Empty once scrolled past `nowAnchor` — out
    /// there the forecast lines are all there is.
    private var visibleSamples: [UsageSample] {
        let buffer = range.interval * 0.05
        let lo = domainStart.addingTimeInterval(-buffer)
        let hi = domainEnd.addingTimeInterval(buffer)
        return samples.filter { $0.date >= lo && $0.date <= hi }
    }

    /// Projected continuations for the two shared limits, in legend order. Built from the live
    /// snapshot's own pace figures rather than a second derivation of the burn rate, so the chart
    /// can never quote a different forecast than the menu does. The per-model scoped window is
    /// left out for the same reason it has no ideal-pace line: it tracks the weekly closely, and
    /// a third dashed pair would only crowd the chart.
    private var forecasts: [BurnForecast] {
        guard let snapshot else { return [] }
        let anchor = nowAnchor
        return [
            burnForecast(series: "Session (5h)", window: snapshot.session, kind: .session, now: anchor),
            snapshot.weekly.flatMap { burnForecast(series: "Weekly", window: $0, kind: .weekly, now: anchor) }
        ].compactMap { $0 }
    }

    /// The forecasts the chart actually draws. On 14d/30d a 5-hour window is a fraction of a
    /// percent of the chart's width: the session projection collapses to a vertical tick and its
    /// label spills off the plot onto the axis — the same reason `isShortRange` withholds the
    /// ideal-pace and over-rate marks there. The weekly projection spans days, so it stays.
    /// The written summary below the chart still reports both, where width costs nothing.
    private var chartForecasts: [BurnForecast] {
        isShortRange ? forecasts : forecasts.filter { $0.series != "Session (5h)" }
    }

    /// Window position that brings the projected finish line into view — centred on the first
    /// run-out the chart draws, or on the furthest reset when nothing runs out. nil when there is
    /// nothing to jump to, or when it is already on screen in the default view.
    private var forecastFocusStart: Date? {
        guard canScroll, !chartForecasts.isEmpty else { return nil }
        let target = chartForecasts.compactMap(\.exhaustsAt).min() ?? chartForecasts.map(\.resetsAt).max()
        guard let target, target > nowAnchor else { return nil }
        let centred = clamp(target.addingTimeInterval(-range.interval / 2))
        return centred > clamp(defaultStart) ? centred : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            burnChart.frame(height: chartHeight)
            if canScroll { scrubber }
            chartLegend
            forecastSummary
        }
        // A new range means a new zoom and a fresh set of samples — snap back to the latest
        // window so the chart always opens on "now" rather than a stale scrolled-away position.
        .onChange(of: range) { _ in windowStart = nil }
    }

    /// The visible time span, shown next to the scrubber so it's clear which slice is on screen —
    /// including the stretch to the right of "now", where only the forecast lives.
    private var scrubber: some View {
        HStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { effectiveStart.timeIntervalSince1970 },
                    set: { windowStart = clamp(Date(timeIntervalSince1970: $0)) }
                ),
                in: scrollMin.timeIntervalSince1970 ... scrollMax.timeIntervalSince1970
            )
            Text(windowLabel)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: 176, alignment: .leading)
            Button {
                windowStart = nil
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .disabled(effectiveStart == clamp(defaultStart))
            .help("Back to the latest readings")

            // Without this the feature is unusable on the short ranges: at 6h the weekly run-out
            // can sit dozens of window-widths to the right.
            Button {
                if let start = forecastFocusStart { windowStart = start }
            } label: {
                Image(systemName: "flag.checkered")
            }
            .buttonStyle(.borderless)
            .disabled(forecastFocusStart == nil)
            .help("Scroll ahead to the projected finish line")
        }
    }

    /// Visible span, with the time included on ranges of a day or less — scrolled into the
    /// forecast, a bare "Jul 28 – Jul 28" says nothing about where you are.
    private var windowLabel: String {
        let dayMonth: Date.FormatStyle = .dateTime.month(.abbreviated).day()
        guard range.interval <= 86400 else {
            return "\(domainStart.formatted(dayMonth)) – \(domainEnd.formatted(dayMonth))"
        }
        let stamped: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()
        let sameDay = Calendar.current.isDate(domainStart, inSameDayAs: domainEnd)
        let end = sameDay
            ? domainEnd.formatted(.dateTime.hour().minute())
            : domainEnd.formatted(stamped)
        return "\(domainStart.formatted(stamped)) – \(end)"
    }

    /// Split into one `@ChartContentBuilder` group per layer, bottom to top. Not organisational
    /// taste: as a single literal body this exceeded what the type-checker will solve, and Charts
    /// reports that as a hard "unable to type-check in reasonable time" error.
    private var burnChart: some View {
        Chart {
            workHourBandMarks
            dayDividerMarks
            idealPaceMarks
            seriesMarks
            overRateMarks
            latestPointMarks
            forecastMarks
            finishLineMarks
            nowDividerMark
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: domainStart ... domainEnd)
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

    @ChartContentBuilder
    private var workHourBandMarks: some ChartContent {
        ForEach(workHourBands, id: \.start) { band in
            RectangleMark(
                xStart: .value("Start", band.start),
                xEnd: .value("End", band.end),
                yStart: .value("Low", 0),
                yEnd: .value("High", 100)
            )
            .foregroundStyle(workHourTint.opacity(0.09))
        }
    }

    @ChartContentBuilder
    private var dayDividerMarks: some ChartContent {
        ForEach(range == .sevenDays ? dayLabelTicks : [], id: \.self) { day in
            RuleMark(x: .value("Day", day))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    /// Dashed "ideal pace" reference per window — rising from 0 % at the window's start to 100 %
    /// at its reset (the 7d lines run flat over weekends). Under the real series.
    @ChartContentBuilder
    private var idealPaceMarks: some ChartContent {
        ForEach(Array(idealPaceLines.enumerated()), id: \.offset) { index, line in
            ForEach(line.points, id: \.0) { point in
                LineMark(
                    x: .value("Time", point.0),
                    y: .value("Used %", point.1),
                    series: .value("Window", "ideal-\(index)")
                )
                .foregroundStyle(color(forSeries: line.series).opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
    }

    @ChartContentBuilder
    private var seriesMarks: some ChartContent {
        ForEach(visibleBurnSeries) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Used %", point.percent),
                series: .value("Window", point.series)
            )
            .foregroundStyle(by: .value("Window", point.series))
            .interpolationMethod(.linear)
        }
    }

    /// Thick red overlay on the Session (5h) line where it climbed faster than normal, drawn after
    /// the series lines so it sits on top. Each segment gets its own series id so contiguous
    /// segments don't get bridged across gaps.
    @ChartContentBuilder
    private var overRateMarks: some ChartContent {
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
    }

    @ChartContentBuilder
    private var latestPointMarks: some ChartContent {
        ForEach(latestBurnPoints) { point in
            PointMark(
                x: .value("Time", point.date),
                y: .value("Used %", point.percent)
            )
            .foregroundStyle(by: .value("Window", point.series))
            .symbolSize(42)
        }
    }

    /// Where each live window is headed from "now" on, at the pace measured so far. Thicker and far
    /// more opaque than the ideal-pace dashes, and on a longer dash, so the two never read as the
    /// same line where they overlap to the right of "now".
    @ChartContentBuilder
    private var forecastMarks: some ChartContent {
        ForEach(chartForecasts) { forecast in
            ForEach(forecast.points, id: \.0) { point in
                LineMark(
                    x: .value("Time", point.0),
                    y: .value("Used %", point.1),
                    series: .value("Window", "forecast-\(forecast.series)")
                )
                .foregroundStyle(color(forSeries: forecast.series).opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [8, 4]))
            }
        }
    }

    /// The finish line itself: a vertical rule where a window is projected to hit 100 %, with the
    /// clock time called out at the crossing.
    @ChartContentBuilder
    private var finishLineMarks: some ChartContent {
        ForEach(Array(chartForecasts.filter { $0.exhaustsAt != nil }.enumerated()), id: \.element.id) { index, forecast in
            let runOut = forecast.exhaustsAt ?? nowAnchor
            RuleMark(x: .value("Runs out", runOut))
                .foregroundStyle(color(forSeries: forecast.series).opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            PointMark(x: .value("Runs out", runOut), y: .value("Used %", 100))
                .foregroundStyle(color(forSeries: forecast.series))
                .symbol(.diamond)
                .symbolSize(58)
                // Each finish line's label sits a row lower than the last, so two windows that
                // run out at nearly the same time don't print over each other.
                .annotation(position: .bottomTrailing, spacing: 6 + CGFloat(index) * 18) {
                    // Down-and-right of the 100 % crossing: down keeps the label inside the plot
                    // (the macOS 14 overflow-resolution API is off-limits at this deployment
                    // target), and right keeps it off the climbing line, which approaches from
                    // the left. Past the crossing the forecast runs flat along 100 %, well above.
                    Text("\(forecast.shortName) out \(runOut, format: .dateTime.hour().minute())")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color(forSeries: forecast.series))
                }
        }
    }

    /// Boundary between what was recorded and what is merely projected. Load-bearing: without it a
    /// dashed line sitting at 100 % reads as history.
    @ChartContentBuilder
    private var nowDividerMark: some ChartContent {
        RuleMark(x: .value("Now", nowAnchor))
            .foregroundStyle(Color.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .annotation(position: .top, spacing: 2) {
                // Labeled, because unlabeled it is indistinguishable from a gridline — and a
                // gridline carries none of the "everything right of here is a guess" meaning.
                Text("now")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
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
                if isShortRange {
                    legendItem(bandSwatch(workHourTint.opacity(0.18)), "Work hours (9:00–18:00)")
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
            if !chartForecasts.isEmpty {
                HStack(spacing: 16) {
                    legendItem(
                        HStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { _ in
                                Capsule().fill(Color.secondary).frame(width: 8, height: 2.5)
                            }
                        },
                        "Forecast at the current pace — scroll right"
                    )
                    legendItem(
                        Rectangle().fill(Color.secondary).frame(width: 1.5, height: 11),
                        "Projected run-out (◆ = hits 100 %)"
                    )
                }
            }
        }
    }

    /// The projection in plain text, so the forecast is readable without scrolling to it — and so
    /// the run-out time on the chart has a written figure to be checked against.
    @ViewBuilder
    private var forecastSummary: some View {
        if !forecasts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(forecasts) { forecast in
                    HStack(spacing: 6) {
                        Image(systemName: forecastSymbol(forecast))
                            .font(.system(size: 10))
                            .foregroundColor(color(forSeries: forecast.series))
                            .frame(width: 12)
                        Text(forecastLine(forecast))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func forecastSymbol(_ forecast: BurnForecast) -> String {
        if !forecast.paceKnown { return "minus.circle" }
        return forecast.exhaustsAt == nil ? "checkmark.circle" : "flame.fill"
    }

    private func forecastLine(_ forecast: BurnForecast) -> String {
        // Matches the menu's "Early" chip: no pace worth trusting yet, so claim nothing beyond
        // where the window resets.
        guard forecast.paceKnown else {
            return "\(forecast.series): too early to project a run-out — resets \(stamp(forecast.resetsAt))."
        }
        guard let runOut = forecast.exhaustsAt else {
            return "\(forecast.series): lands at \(Int(forecast.percentAtReset.rounded()))% by \(stamp(forecast.resetsAt)) — won't run out."
        }
        guard let inTime = forecast.timeToExhaust, inTime > 0 else {
            return "\(forecast.series): exhausted — refills \(stamp(forecast.resetsAt))."
        }
        let early = forecast.resetsAt.timeIntervalSince(runOut)
        return "\(forecast.series): runs out \(stamp(runOut)) — in \(formatDuration(inTime)), \(formatDuration(early)) before its reset."
    }

    /// Clock time for anything inside the next day, date and time beyond it — a weekly reset five
    /// days out needs the day, a session run-out in 40 minutes does not.
    private func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
    /// banding to mean anything. Spans the visible domain, not the data, so bands fill the whole
    /// window even when scrolled to a region with sparse samples.
    private var workHourBands: [(start: Date, end: Date)] {
        guard isShortRange else { return [] }
        let lo = domainStart, hi = domainEnd
        guard hi > lo else { return [] }
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
        isShortRange ? fastBurnSegments(in: visibleSamples) : []
    }

    /// "Ideal pace" polylines for every quota window visible in the sampled history — a dashed
    /// reference rising from 0 % at a window's start to 100 % at its reset. 5h session windows
    /// open on activity, so their starts come from the recorded samples; 7d windows reset on a
    /// fixed schedule, so past ones sit at exact multiples of the duration back from the known
    /// reset. Points beyond the visible domain are left in — `chartXScale` clips them, and the
    /// off-screen neighbour keeps the slope correct where a line enters/leaves the window.
    private var idealPaceLines: [(series: String, points: [(Date, Double)])] {
        let lo = domainStart, hi = domainEnd
        guard hi > lo else { return [] }
        var lines: [(series: String, points: [(Date, Double)])] = []

        // Straight 0→100 % line: the right reference for a 5h session, which is spent within a
        // single day with no weekend to account for.
        func addLinear(_ series: String, windowStart: Date, duration: TimeInterval) {
            let end = windowStart.addingTimeInterval(duration)
            guard end > lo, windowStart < hi else { return }
            lines.append((series, [(windowStart, 0), (end, 100)]))
        }

        // Weekend-aware line for the weekly windows (see `weekdayPacedPoints`): climbs Mon–Fri,
        // flat Sat/Sun. Falls back to a straight line if the window somehow has no weekday time.
        func addWeekdayPaced(_ series: String, windowStart: Date, duration: TimeInterval) {
            guard windowStart.addingTimeInterval(duration) > lo, windowStart < hi else { return }
            if let points = weekdayPacedPoints(windowStart: windowStart, duration: duration) {
                lines.append((series, points.map { ($0.date, $0.percent) }))
            } else {
                addLinear(series, windowStart: windowStart, duration: duration)
            }
        }

        // Per-session ideal lines only where a 5h window is wide enough to read; on 14d/30d
        // they would be dozens of near-vertical dashes across the whole chart.
        if isShortRange {
            let sessionDuration: TimeInterval = 5 * 3600
            let sessionResets = snapshot?.session.resetsAt
            var windows = sessionWindows(in: visibleSamples, duration: sessionDuration, lastResetsAt: sessionResets)
            // Scrolled into the forecast there are no samples left, so the call above yields
            // nothing — yet the open window's ideal pace is exactly what the projection is meant
            // to be compared against out there. Take it straight from the known reset.
            if let reset = sessionResets, !windows.contains(where: { $0.end == reset }) {
                windows.append((reset.addingTimeInterval(-sessionDuration), reset))
            }
            for window in windows {
                addLinear("Session (5h)", windowStart: window.start, duration: sessionDuration)
            }
        }

        func addPeriodic(_ series: String, _ window: RateWindow?) {
            guard let window, let resetsAt = window.resetsAt else { return }
            for windowStart in periodicWindowStarts(resetsAt: resetsAt, duration: window.windowDuration, visibleFrom: lo, visibleTo: hi) {
                addWeekdayPaced(series, windowStart: windowStart, duration: window.windowDuration)
            }
        }
        // Only the two shared limits get an ideal-pace reference: the 5h session (above) and the
        // overall 7d weekly. The per-model scoped window (e.g. Fable) is deliberately left without
        // one — its line would just crowd the chart alongside the weekly it tracks closely.
        addPeriodic("Weekly", snapshot?.weekly)
        return lines
    }

    /// Ticks anchored at midnight and stepped by `xAxisStyle`, instead of Charts' automatic
    /// `.stride`, which anchors wherever the data happens to start — an arbitrary offset that
    /// would just as often miss 9:00/18:00 as hit them. Anchoring at midnight with a stride
    /// that divides both 9 and 24 (3h, used for 1d/7d) makes those work-hour band edges land
    /// exactly on a tick every time, and keeps every other tick evenly spaced around them.
    /// Spans the visible domain so ticks stay put as the window scrolls.
    private var xAxisTicks: [Date] {
        let lo = domainStart, hi = domainEnd
        guard hi > lo else { return [] }
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

    /// Tick stride keyed off the fixed visible window width (`range.interval`), so labels never
    /// collapse to a repeated date the way an auto `.stride` would over a ~1-day span. Short
    /// windows also show the time so ticks within one day stay distinct.
    private var xAxisStyle: (unit: Calendar.Component, count: Int, showTime: Bool) {
        // 6h/12h/1d/7d use a fixed hour stride that divides 9 — so xAxisTicks' midnight anchor
        // puts 9:00 and 18:00 exactly on a tick (the work-hour band edges) regardless of window.
        if range == .sixHours { return (.hour, 1, true) }   // 6h span too short for a 3h stride
        if range == .twelveHours || range == .oneDay || range == .sevenDays { return (.hour, 3, true) }
        switch range.interval {
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

    /// Which series ever appear across the whole recorded history — computed from the full
    /// (not the visible) set so the legend and color scale stay stable while scrolling.
    private var presentSeries: Set<String> {
        var present: Set<String> = ["Session (5h)"]
        for sample in samples {
            if sample.weekly != nil { present.insert("Weekly") }
            if sample.opus != nil { present.insert("Opus (7d)") }
            if sample.sonnet != nil { present.insert("Sonnet (7d)") }
            if sample.scoped != nil {
                present.insert(sample.scopedModel.map { "\($0) (7d)" } ?? "Model (7d)")
            }
        }
        return present
    }

    /// Stable legend order: fixed windows first, then any per-model series present.
    private var seriesLegendOrder: [String] {
        let fixed = ["Session (5h)", "Weekly", "Opus (7d)", "Sonnet (7d)"]
        let present = presentSeries
        var order = fixed.filter(present.contains)
        order.append(contentsOf: present.subtracting(fixed).sorted())
        return order
    }

    /// Burn points for the visible window only — the lines the chart draws while scrolled to
    /// this slice.
    private var visibleBurnSeries: [BurnPoint] {
        var points: [BurnPoint] = []
        for sample in visibleSamples {
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
        // A series with a single in-window point can't draw a line — it would only add a
        // stray legend entry and a lone dot.
        let counts = Dictionary(grouping: points, by: \.series).mapValues(\.count)
        return points.filter { counts[$0.series, default: 0] >= 2 }
    }

    /// Dots at the most recent recorded value per series. Only computed while that reading is
    /// inside the visible window — scrolled away from it, into history or into the forecast, the
    /// domain would clip these anyway, so there is nothing to draw.
    private var latestBurnPoints: [BurnPoint] {
        guard let last = samples.last, last.date >= domainStart, last.date <= domainEnd else { return [] }
        var points = [BurnPoint(date: last.date, series: "Session (5h)", percent: last.session)]
        if let weekly = last.weekly {
            points.append(BurnPoint(date: last.date, series: "Weekly", percent: weekly))
        }
        if let opus = last.opus {
            points.append(BurnPoint(date: last.date, series: "Opus (7d)", percent: opus))
        }
        if let sonnet = last.sonnet {
            points.append(BurnPoint(date: last.date, series: "Sonnet (7d)", percent: sonnet))
        }
        if let scoped = last.scoped {
            let label = last.scopedModel.map { "\($0) (7d)" } ?? "Model (7d)"
            points.append(BurnPoint(date: last.date, series: label, percent: scoped))
        }
        return points
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

/// Where one quota window is headed, as a polyline the chart can draw to the right of "now".
/// `points` are unlabeled `(Date, Double)` pairs to match `idealPaceLines`, which Charts' `ForEach`
/// keys by `\.0`.
struct BurnForecast: Identifiable {
    let series: String
    let points: [(Date, Double)]
    /// When the line reaches 100 % — the projected finish line. nil when the window is projected
    /// to survive all the way to its reset.
    let exhaustsAt: Date?
    let resetsAt: Date
    let percentAtReset: Double
    /// Time from the anchor to exhaustion, so captions can quote the same figure the menu does.
    let timeToExhaust: TimeInterval?
    /// False when there is no trustworthy pace to extrapolate from — either the window is minutes
    /// old, or its tier is still `.early`. The line is then flat at the current level and marks
    /// only where the reset falls, so captions must not present it as a projection.
    let paceKnown: Bool

    var id: String { series }

    /// Short label for on-chart annotations, where "Session (5h)" is more than fits.
    var shortName: String { series.split(separator: " ").first.map(String.init) ?? series }
}

/// Build a forecast straight off a live `RateWindow`, reusing its own pace figures rather than
/// re-deriving them — that way the chart's run-out time and the menu's "exhausts in …" are the
/// same number by construction, not by coincidence.
///
/// The same applies to *withholding* a forecast: while `paceTier` is `.early` the whole-window
/// average is noise on a tiny denominator, and `Recommender` deliberately makes no exhaustion
/// claim. Minutes into a window the burn rate is already non-nil, so without this gate the chart
/// would plant a confident finish line at the exact moment the menu shows an "Early" chip and says
/// nothing — a contradiction that would appear at the start of every single session.
func burnForecast(series: String, window: RateWindow, kind: WindowKind, now: Date) -> BurnForecast? {
    guard let resetsAt = window.resetsAt else { return nil }
    let trusted = window.paceTier(kind: kind) != .early
    return burnForecastShape(
        series: series,
        usedPercent: window.usedPercent,
        timeToExhaustion: trusted ? window.timeToExhaustion : nil,
        projectedUsageAtReset: trusted ? window.projectedUsageAtReset : nil,
        resetsAt: resetsAt,
        now: now
    )
}

/// Shape of a projected line: from the last measurement forward, climbing at the pace implied by
/// `timeToExhaustion` until it hits 100 %, then flat along 100 % up to the reset — which is what
/// actually happens, since a spent quota stays spent until it refills. A window projected to
/// survive simply ends at its reset at `projectedUsageAtReset`, with no finish line. With no
/// measurable rate yet the line is flat at the current level: still worth drawing, because it
/// marks where the reset falls. Returns nil when the reset is already behind `now` (a stale
/// snapshot) — there is nothing left to project.
func burnForecastShape(
    series: String,
    usedPercent: Double,
    timeToExhaustion: TimeInterval?,
    projectedUsageAtReset: Double?,
    resetsAt: Date,
    now: Date
) -> BurnForecast? {
    guard resetsAt > now else { return nil }
    let used = min(100, max(0, usedPercent))

    // Already spent: a measured fact, not a forecast, so the finish line is behind us not ahead.
    if used >= 100 {
        return BurnForecast(series: series, points: [(now, 100), (resetsAt, 100)],
                            exhaustsAt: now, resetsAt: resetsAt, percentAtReset: 100,
                            timeToExhaust: 0, paceKnown: true)
    }

    if let remaining = timeToExhaustion, remaining >= 0 {
        let exhaustsAt = now.addingTimeInterval(remaining)
        if exhaustsAt <= resetsAt {
            var points: [(Date, Double)] = [(now, used), (exhaustsAt, 100)]
            if exhaustsAt < resetsAt { points.append((resetsAt, 100)) }
            return BurnForecast(series: series, points: points, exhaustsAt: exhaustsAt,
                                resetsAt: resetsAt, percentAtReset: 100,
                                timeToExhaust: remaining, paceKnown: true)
        }
    }

    let atReset = min(100, max(used, projectedUsageAtReset ?? used))
    return BurnForecast(series: series, points: [(now, used), (resetsAt, atReset)],
                        exhaustsAt: nil, resetsAt: resetsAt, percentAtReset: atReset,
                        timeToExhaust: nil,
                        paceKnown: timeToExhaustion != nil || projectedUsageAtReset != nil)
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
///
/// A drop only counts as a reset if the session had climbed to at least `minResetPeak` first:
/// the endpoint occasionally reports a lone 1 % blip during an idle stretch, and treating that
/// as a reset would draw a full 5-hour ideal-pace diagonal back across hours of genuine
/// inactivity — a session that never happened.
func sessionWindows(
    in samples: [UsageSample],
    duration: TimeInterval = 5 * 3600,
    lastResetsAt: Date? = nil,
    minResetPeak: Double = 5
) -> [(start: Date, end: Date)] {
    var windows: [(start: Date, end: Date)] = []
    var runStart = 0
    for i in samples.indices {
        let isTail = i == samples.count - 1
        let drops = !isTail && samples[i + 1].session < samples[i].session && samples[i].session >= minResetPeak
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

/// Points of a weekend-aware "ideal pace" line for a weekly window: 100 % is spread evenly
/// across the window's weekday SECONDS, so the line climbs Mon–Fri, runs flat on Sat/Sun, and
/// still reaches exactly 100 % at the reset. Partial edge days (the reset rarely lands at
/// midnight) count proportionally. Returns nil when the window has no weekday seconds at all,
/// so the caller can fall back to a plain straight line.
func weekdayPacedPoints(windowStart: Date, duration: TimeInterval) -> [(date: Date, percent: Double)]? {
    let windowEnd = windowStart.addingTimeInterval(duration)
    let cal = Calendar.current
    // A day is a weekend day by the calendar weekday of its start instant (1 = Sun, 7 = Sat).
    var segments: [(end: Date, isWeekend: Bool)] = []
    var t = windowStart
    while t < windowEnd {
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t)) else { break }
        let segEnd = min(nextDay, windowEnd)
        let weekday = cal.component(.weekday, from: t)
        segments.append((segEnd, weekday == 1 || weekday == 7))
        t = segEnd
    }
    var segStart = windowStart
    var workSeconds = 0.0
    for seg in segments {
        if !seg.isWeekend { workSeconds += seg.end.timeIntervalSince(segStart) }
        segStart = seg.end
    }
    guard workSeconds > 0 else { return nil }
    var points: [(date: Date, percent: Double)] = [(windowStart, 0)]
    var cum = 0.0
    segStart = windowStart
    for seg in segments {
        if !seg.isWeekend { cum += seg.end.timeIntervalSince(segStart) / workSeconds * 100 }
        points.append((seg.end, cum))
        segStart = seg.end
    }
    return points
}

/// Starts of every `duration`-long window whose span overlaps the visible range, walking back
/// from a known `resetsAt`. The stop test is `end > visibleFrom` (not `end - duration <
/// visibleTo`): when the visible range is scrolled entirely into the past, the newest windows
/// sit to its right and must be stepped over rather than ending the walk — otherwise the window
/// actually on screen is missed and its ideal-pace line disappears.
func periodicWindowStarts(resetsAt: Date, duration: TimeInterval, visibleFrom: Date, visibleTo: Date) -> [Date] {
    guard duration > 0 else { return [] }
    var starts: [Date] = []
    var end = resetsAt
    while end > visibleFrom {
        let windowStart = end.addingTimeInterval(-duration)
        if windowStart < visibleTo { starts.append(windowStart) }
        end = end.addingTimeInterval(-duration)
    }
    return starts
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
    // A lone 1 % blip dropping back to 0 is NOT a reset (peak 1 % < 5 %), so it adds no
    // completed window — only the API-known tail window remains. Without the peak gate this
    // would be 2 windows, the spurious one drawing a 5h diagonal across an idle stretch.
    let blip = sessionWindows(in: [s(0, 0), s(4, 1), s(8, 0)], duration: dur, lastResetsAt: reset)
    assert(blip.count == 1 && blip[0].end == reset)
    // A real drop from a meaningful peak (50 % → 0) still counts as a reset.
    let real = sessionWindows(in: [s(0, 0), s(4, 50), s(8, 0)], duration: dur, lastResetsAt: reset)
    assert(real.count == 2)

    // Weekend-aware weekly pacing — structural invariants only, so the check is timezone-robust
    // (no absolute-percentage assumptions that depend on the machine's calendar/zone).
    let cal = Calendar.current
    let wkStart = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    let wk = weekdayPacedPoints(windowStart: wkStart, duration: 7 * 86400)!
    assert(wk.first!.percent == 0)                                   // starts at 0
    assert(abs(wk.last!.percent - 100) < 0.001)                      // reaches exactly 100 at reset
    assert(zip(wk, wk.dropFirst()).allSatisfy { $0.percent <= $1.percent + 1e-9 })  // never decreases
    // The climb accumulated over segments that begin on a Sat/Sun is ~0 (those days are flat),
    // while the whole line climbs 100 — so the weekend really is where it plateaus.
    let weekendClimb = zip(wk, wk.dropFirst()).reduce(0.0) { acc, pair in
        let weekday = cal.component(.weekday, from: pair.0.date)
        return acc + (weekday == 1 || weekday == 7 ? pair.1.percent - pair.0.percent : 0)
    }
    assert(weekendClimb < 0.001)

    // periodicWindowStarts: a visible range scrolled entirely into the PAST of the reset still
    // yields the window covering it. This is the regression that once drew nothing when scrolled
    // back — the walk must step over the newer windows sitting to the range's right.
    let wReset = Date(timeIntervalSince1970: 1_700_000_000)
    let wDur: TimeInterval = 7 * 86400
    let from = wReset.addingTimeInterval(-14 * 86400), to = wReset.addingTimeInterval(-13 * 86400)
    let starts = periodicWindowStarts(resetsAt: wReset, duration: wDur, visibleFrom: from, visibleTo: to)
    assert(!starts.isEmpty)
    assert(starts.allSatisfy { $0 < to && $0.addingTimeInterval(wDur) > from })   // each overlaps the range

    // Forecast shapes — the lines you scroll right to see.
    let fNow = Date(timeIntervalSince1970: 1_700_000_000)
    let fReset = fNow.addingTimeInterval(4 * 3600)
    // Projected to run out: rises to 100 % at the run-out instant, then flat to the reset.
    let runsOut = burnForecastShape(series: "Session (5h)", usedPercent: 50,
                                    timeToExhaustion: 3600, projectedUsageAtReset: 150,
                                    resetsAt: fReset, now: fNow)!
    assert(runsOut.exhaustsAt == fNow.addingTimeInterval(3600))
    assert(runsOut.timeToExhaust == 3600)
    assert(runsOut.points.count == 3)
    assert(runsOut.points[0].1 == 50 && runsOut.points[1].1 == 100 && runsOut.points[2].1 == 100)
    assert(runsOut.points[2].0 == fReset)
    assert(runsOut.shortName == "Session")
    // Survives the window: one segment ending at the reset, no finish line.
    let survives = burnForecastShape(series: "Weekly", usedPercent: 40,
                                     timeToExhaustion: 40 * 3600, projectedUsageAtReset: 62,
                                     resetsAt: fReset, now: fNow)!
    assert(survives.exhaustsAt == nil && survives.timeToExhaust == nil)
    assert(survives.points.count == 2 && abs(survives.points[1].1 - 62) < 1e-9)
    // Exhaustion landing exactly on the reset is not a flat tail — just the two points.
    let exact = burnForecastShape(series: "Weekly", usedPercent: 40, timeToExhaustion: 4 * 3600,
                                  projectedUsageAtReset: 100, resetsAt: fReset, now: fNow)!
    assert(exact.exhaustsAt == fReset && exact.points.count == 2)
    // Already spent: flat at 100 %, and the finish line is now rather than a future instant.
    let spent = burnForecastShape(series: "Weekly", usedPercent: 100, timeToExhaustion: 0,
                                  projectedUsageAtReset: 100, resetsAt: fReset, now: fNow)!
    assert(spent.exhaustsAt == fNow && spent.points.allSatisfy { $0.1 == 100 })
    // No measurable rate yet — flat at the current level, still marking where the reset falls.
    let flat = burnForecastShape(series: "Session (5h)", usedPercent: 12, timeToExhaustion: nil,
                                 projectedUsageAtReset: nil, resetsAt: fReset, now: fNow)!
    assert(flat.exhaustsAt == nil && !flat.paceKnown)
    assert(flat.points.count == 2 && flat.points[0].1 == 12 && flat.points[1].1 == 12)
    assert(runsOut.paceKnown && survives.paceKnown && spent.paceKnown)
    // A reset already behind us is a stale snapshot — nothing to project.
    assert(burnForecastShape(series: "Weekly", usedPercent: 10, timeToExhaustion: 3600,
                             projectedUsageAtReset: 20,
                             resetsAt: fNow.addingTimeInterval(-60), now: fNow) == nil)
    // The early-warmup gate. Minutes into a 5h window a burn rate already exists, but the menu
    // withholds every exhaustion claim while the tier is `.early` — so the chart must withhold its
    // finish line too. This is the state at the start of every single session.
    let fresh = RateWindow(usedPercent: 8, windowDuration: 5 * 3600,
                           resetsAt: Date().addingTimeInterval(4 * 3600 + 50 * 60))  // ~10m elapsed
    assert(fresh.paceTier(kind: .session) == .early)
    assert(fresh.timeToExhaustion != nil)   // a rate exists — the tier gate is what withholds, not nil-ness
    let freshForecast = burnForecast(series: "Session (5h)", window: fresh, kind: .session, now: Date())!
    assert(freshForecast.exhaustsAt == nil && !freshForecast.paceKnown)
    // Past the gate the same window does get a finish line.
    let mature = RateWindow(usedPercent: 90, windowDuration: 5 * 3600,
                            resetsAt: Date().addingTimeInterval(3600))               // 4h elapsed
    assert(mature.paceTier(kind: .session) != .early)
    let matureForecast = burnForecast(series: "Session (5h)", window: mature, kind: .session, now: Date())!
    assert(matureForecast.paceKnown && matureForecast.exhaustsAt != nil)

    // Wired to a live RateWindow, the forecast stays inside that window: it never projects past
    // the window's own reset, and the line never falls. Asserted as invariants rather than exact
    // figures — `RateWindow`'s pace properties read the wall clock, so two reads of the same
    // property differ by microseconds and an equality check on them would flake.
    let live = RateWindow(usedPercent: 60, windowDuration: 5 * 3600,
                          resetsAt: Date().addingTimeInterval(2 * 3600))
    let liveReset = live.resetsAt!
    let liveForecast = burnForecast(series: "Session (5h)", window: live, kind: .session, now: Date())!
    assert(liveForecast.resetsAt == liveReset)
    assert(liveForecast.points.allSatisfy { $0.0 <= liveReset })
    assert((liveForecast.exhaustsAt ?? liveReset) <= liveReset)
    assert(liveForecast.points.count >= 2)
    assert(zip(liveForecast.points, liveForecast.points.dropFirst()).allSatisfy { $0.1 <= $1.1 + 1e-9 })
}
#endif
