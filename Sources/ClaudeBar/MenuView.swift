import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            if let snap = store.snapshot {
                windowRow(title: "Session (5 hours)", window: snap.session, icon: "clock.fill")
                if let weekly = snap.weekly {
                    Divider().padding(.horizontal, 16)
                    windowRow(title: "Weekly", window: weekly, icon: "calendar")
                }
                if let sonnet = snap.sonnetWeekly {
                    Divider().padding(.horizontal, 16)
                    windowRow(title: "Sonnet (weekly)", window: sonnet, icon: "sparkle")
                }
                if let opus = snap.opusWeekly {
                    Divider().padding(.horizontal, 16)
                    windowRow(title: "Opus (weekly)", window: opus, icon: "sparkles")
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

    private func windowRow(title: String, window: RateWindow, icon: String) -> some View {
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
                    .foregroundColor(colorForPercent(window.remainingPercent))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForPercent(window.remainingPercent))
                        .frame(width: geo.size.width * CGFloat(window.remainingPercent / 100), height: 6)
                        .animation(.easeInOut(duration: 0.4), value: window.remainingPercent)
                }
            }
            .frame(height: 6)

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
                        let projInt = Int(projected.rounded())
                        Text("projected: ~\(projInt)%")
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

            Divider().padding(.horizontal, 14)

            HStack {
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

    private func colorForPercent(_ remaining: Double) -> Color {
        if remaining > 40 { return .green }
        if remaining > 20 { return .yellow }
        if remaining > 10 { return .orange }
        return .red
    }
}
