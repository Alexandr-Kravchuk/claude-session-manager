import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var updater: AutoUpdater
    @AppStorage("com.claudebar.fillBarsAsUsed") private var fillBars = false
    @AppStorage(UsageStore.newPaceUIKey) private var newPaceUI = true
    @AppStorage(AutoUpdater.autoUpdateKey) private var autoUpdate = true

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            if let snap = store.snapshot {
                windowRow(title: "Session (5 hours)", window: snap.session, icon: "clock.fill", kind: .session)
                if let weekly = snap.weekly {
                    Divider().padding(.horizontal, 16)
                    windowRow(title: "Weekly", window: weekly, icon: "calendar", kind: .weekly)
                }
                if let sonnet = snap.sonnetWeekly {
                    Divider().padding(.horizontal, 16)
                    windowRow(title: "Sonnet (weekly)", window: sonnet, icon: "sparkle", kind: .weekly)
                }
                if let opus = snap.opusWeekly {
                    Divider().padding(.horizontal, 16)
                    windowRow(title: "Opus (weekly)", window: opus, icon: "sparkles", kind: .weekly)
                }
            } else if let error = store.errorMessage {
                errorSection(message: error)
            } else {
                loadingSection
            }
            Divider()
            footerSection
        }
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { Task { await store.refreshIfStale() } }
    }

    private var headerSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if store.isDegraded {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Data may be outdated")
                            .font(.system(size: 13, weight: .semibold))
                        Group {
                            if let error = store.errorMessage {
                                Text(error)
                            } else if let updated = store.lastUpdated {
                                Text("Updated ") + Text(updated, style: .relative) + Text(" ago")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                } else if let rec = store.recommendation {
                    Image(systemName: rec.statusSymbol)
                        .foregroundColor(store.statusColor)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.headline)
                            .font(.system(size: 13, weight: .semibold))
                        if let modelLine = rec.modelLine {
                            Text(modelLine)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                } else if store.isLoading {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading…").font(.system(size: 13))
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                    Text("Claude Code Limits").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func windowRow(title: String, window: RateWindow, icon: String, kind: WindowKind) -> some View {
        if newPaceUI {
            paceRow(title: title, window: window, icon: icon, kind: kind)
        } else {
            legacyRow(title: title, window: window, icon: icon)
        }
    }

    // MARK: - New pace UI

    private func paceRow(title: String, window: RateWindow, icon: String, kind: WindowKind) -> some View {
        let tier = window.paceTier(kind: kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                paceChip(tier, window: window)
                // Always primary: the measured level is a fact, the pace verdict is a
                // forecast — they live in separate visual channels.
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
            }

            paceBar(window: window, tier: tier, kind: kind)

            if let resetIn = window.timeUntilReset {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Resets in \(formatDuration(resetIn))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    forecastText(window: window, tier: tier, kind: kind)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(title: title, window: window, tier: tier, kind: kind))
    }

    private func paceChip(_ tier: PaceTier, window: RateWindow) -> some View {
        HStack(spacing: 3) {
            Image(systemName: tier.symbol)
                .font(.system(size: 8))
            Text(tier.word)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(tier.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tier.color.opacity(0.15)))
        .layoutPriority(1)
        .help(chipHelp(window, tier: tier))
    }

    private func chipHelp(_ window: RateWindow, tier: PaceTier) -> String {
        // Early-gated forecasts are deliberately untrusted — don't leak them here.
        guard tier != .early, let projected = window.projectedUsageAtReset else {
            return "Pace vs even burn — no forecast yet"
        }
        return "Pace vs even burn — projected to use \(Int(projected.rounded()))% of this window by reset, at average pace since window start"
    }

    /// Bullet-style bar: neutral base fill, a tier-colored band for the gap between
    /// the fill edge and the even-pace caret, and the caret itself. Geometry is shared
    /// by both fill modes: `a` is the fill edge, `b` the even-pace position.
    private func paceBar(window: RateWindow, tier: PaceTier, kind: WindowKind) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fillEdge = min(100.0, max(0.0, fillBars ? window.usedPercent : window.remainingPercent))
            let caret: Double? = window.elapsedFraction.map {
                min(100.0, max(0.0, (fillBars ? $0 : 1 - $0) * 100))
            }
            // Tier-gated: respects the early gate and the anti-flap downgrade, so the
            // bar can't flash red while the chip says "Early"/"Hot".
            let overshoot = tier == .runsOut && (window.projectedUsageAtReset ?? 0) >= 100

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 6)

                if let caret {
                    let lower = min(fillEdge, caret)
                    let upper = max(fillEdge, caret)
                    let band = bandColor(tier: tier, window: window, kind: kind)

                    // Base fill — the undisputed part, no judgment. In remaining mode
                    // an overshoot dooms what's left, so it tints red. With no verdict
                    // band the base runs to the actual fill edge, so the bar never
                    // under-reports the measured level.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(overshoot && !fillBars ? Color.red.opacity(0.35) : Color.secondary.opacity(0.45))
                        .frame(width: width * (band == nil ? fillEdge : lower) / 100, height: 6)

                    if let band, upper > lower {
                        Rectangle()
                            .fill(band)
                            .frame(width: max(2, width * (upper - lower) / 100), height: 6)
                            .offset(x: width * lower / 100)
                    }

                    if overshoot {
                        if fillBars {
                            Rectangle()
                                .fill(Color.red.opacity(0.35))
                                .frame(width: width * (100 - upper) / 100, height: 6)
                                .offset(x: width * upper / 100)
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.red)
                                .shadow(color: Color(NSColor.windowBackgroundColor), radius: 1)
                                .offset(x: width - 7)
                        } else {
                            Image(systemName: "arrowtriangle.left.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.red)
                                .shadow(color: Color(NSColor.windowBackgroundColor), radius: 1)
                        }
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 2, height: 12)
                        .offset(x: max(0, min(width - 2, width * caret / 100 - 1)))
                        .help("Even-pace mark — the fill should end near here")
                } else {
                    // No reset date — no pace reference, just a neutral level.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: width * fillEdge / 100, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: window.remainingPercent)
        }
        .frame(height: 12)
    }

    /// Which color the deviation band gets — and whether it's drawn at all. A slow
    /// session is lunch, not waste, so its surplus stays unpainted except for the
    /// late-window "use it or lose it" hint.
    private func bandColor(tier: PaceTier, window: RateWindow, kind: WindowKind) -> Color? {
        switch tier {
        case .early:
            return nil
        case .idle, .hot, .runsOut:
            return tier.color
        case .onPace:
            if kind == .session {
                return sessionLateHint(window) ? Color.blue.opacity(0.35) : nil
            }
            return tier.color
        }
    }

    /// Last hour of the session window with half the quota still projected unused.
    private func sessionLateHint(_ window: RateWindow) -> Bool {
        guard let resetIn = window.timeUntilReset, let left = window.projectedLeftAtReset else { return false }
        return resetIn <= 3600 && left >= 50
    }

    @ViewBuilder
    private func forecastText(window: RateWindow, tier: PaceTier, kind: WindowKind) -> some View {
        let caption = Font.system(size: 10)
        if kind == .session, sessionLateHint(window),
           let left = window.projectedLeftAtReset, let resetIn = window.timeUntilReset {
            Text("~\(Int(left.rounded()))% expires in \(formatDuration(resetIn)) — go big")
                .font(caption)
                .foregroundColor(.blue)
        } else {
            switch tier {
            case .early:
                Text("No forecast yet")
                    .font(caption)
                    .italic()
                    .foregroundColor(.secondary)
            case .idle:
                Text("~\(Int((window.projectedLeftAtReset ?? 0).rounded()))% will go unused")
                    .font(caption)
                    .foregroundColor(.blue)
            case .onPace, .hot:
                // max(0, …): the anti-flap hot state can carry a >100% projection.
                Text("~\(Int(max(0, window.projectedLeftAtReset ?? 0).rounded()))% left at reset")
                    .font(caption)
                    .foregroundColor(tier == .hot ? .orange : .secondary)
            case .runsOut:
                Text(runsOutCaption(window))
                    .font(caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func runsOutCaption(_ window: RateWindow) -> String {
        if window.remainingPercent < 5 {
            return "Exhausted — resets in \(formatDuration(window.timeUntilReset ?? 0))"
        }
        if let runOut = window.timeToExhaustion {
            if let resetIn = window.timeUntilReset, resetIn > runOut {
                return "Runs out in \(formatDuration(runOut)) — \(formatDuration(resetIn - runOut)) early"
            }
            return "Runs out in \(formatDuration(runOut))"
        }
        return "Will exhaust before reset"
    }

    private func accessibilityText(title: String, window: RateWindow, tier: PaceTier, kind: WindowKind) -> String {
        let pacePhrase: String
        switch tier {
        case .early: pacePhrase = "no forecast yet"
        case .idle: pacePhrase = "idle pace"
        case .onPace: pacePhrase = "on pace"
        case .hot: pacePhrase = "hot pace"
        case .runsOut: pacePhrase = "running out"
        }
        var parts = [
            "\(title): \(Int(window.remainingPercent.rounded())) percent left",
            pacePhrase,
        ]
        if kind == .session, sessionLateHint(window), let left = window.projectedLeftAtReset {
            parts.append("about \(Int(left.rounded())) percent expires unused before reset")
        } else if tier != .early, let left = window.projectedLeftAtReset {
            parts.append(left >= 0
                ? "about \(Int(left.rounded())) percent left at reset"
                : "projected to run out before reset")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Legacy row

    private func legacyRow(title: String, window: RateWindow, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(colorForWindow(window))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)
                    let barPercent = min(100.0, max(0.0, fillBars ? window.usedPercent : window.remainingPercent))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForWindow(window))
                        .frame(width: geo.size.width * CGFloat(barPercent / 100), height: 6)
                        .animation(.easeInOut(duration: 0.4), value: window.remainingPercent)
                    if let projected = window.projectedUsageAtReset {
                        let markerPercent = min(100.0, max(0.0, fillBars ? projected : 100.0 - projected))
                        let markerX = geo.size.width * CGFloat(markerPercent / 100.0)
                        Rectangle()
                            .fill(Color.white.opacity(0.75))
                            .frame(width: 2, height: 9)
                            .offset(x: max(0, min(geo.size.width - 2, markerX - 1)))
                            .animation(.easeInOut(duration: 0.4), value: markerX)
                    }
                }
            }
            .frame(height: 9)

            if let resetIn = window.timeUntilReset {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Resets in \(formatDuration(resetIn))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let projected = window.projectedUsageAtReset {
                        let atReset = max(0, Int((100.0 - projected).rounded()))
                        Text("~\(atReset)% left at reset")
                            .font(.system(size: 10))
                            .foregroundColor(projected > 90 ? .orange : .secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func errorSection(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var loadingSection: some View {
        HStack {
            ProgressView().scaleEffect(0.8)
            Text("Fetching data…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 16)
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                )) {
                    Text("Launch at Login")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            HStack {
                Toggle(isOn: $fillBars) {
                    Text("Fill bars as limit is used")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            HStack {
                Toggle(isOn: Binding(
                    get: { newPaceUI },
                    set: { newPaceUI = $0; store.objectWillChange.send() }
                )) {
                    Text("New pace UI")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            HStack {
                Toggle(isOn: Binding(
                    get: { autoUpdate },
                    set: {
                        autoUpdate = $0
                        if $0 { updater.startPeriodicCheck() }
                        else { updater.stopPeriodicCheck() }
                    }
                )) {
                    Text("Auto Update")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            Divider().padding(.horizontal, 14)

            updateSection

            HStack {
                Text("v\(AutoUpdater.currentVersion)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
                if let updated = store.lastUpdated {
                    let timeColor = store.isStale ? Color.orange.opacity(0.9) : Color.secondary.opacity(0.7)
                    Text(updated, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(timeColor)
                    + Text(" ago")
                        .font(.system(size: 10))
                        .foregroundColor(timeColor)
                }
                Spacer()
                Button {
                    Task { await store.refresh(force: true) }
                    Task { await updater.checkForUpdates(autoInstall: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(store.isLoading)

                Divider().frame(height: 14)

                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        if updater.isUpdating, let progress = updater.progress {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text(progress)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider().padding(.horizontal, 14)
        } else if updater.updateAvailable, let version = updater.latestVersion {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 12))
                Text("v\(version) available")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("Update") {
                    Task { await updater.performUpdate() }
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider().padding(.horizontal, 14)
        } else if let error = updater.error {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.system(size: 10))
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    Task { await updater.checkForUpdates() }
                } label: {
                    Text("Retry")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            Divider().padding(.horizontal, 14)
        }
    }

    private func colorForWindow(_ window: RateWindow) -> Color {
        guard let projected = window.projectedUsageAtReset else { return .green }
        let leftAtReset = 100.0 - projected
        if leftAtReset < 0 { return .red }
        if leftAtReset < 5 { return .yellow }
        return .green
    }
}

extension PaceTier {
    var color: Color {
        switch self {
        case .early: return .secondary
        case .idle: return .blue
        case .onPace: return .green
        case .hot: return .orange
        case .runsOut: return .red
        }
    }
}
