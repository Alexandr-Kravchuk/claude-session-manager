import SwiftUI

struct LimitAlertView: View {
    let entries: [LimitAlertEntry]
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    /// Matches the codebase-wide "exhausted" cutoff (RateWindow.paceTier's `.runsOut`,
    /// UsageStore.recoveryText) so this dialog's red/orange split never disagrees with what
    /// the menu bar is already showing for the same number.
    private var isCritical: Bool {
        entries.contains { $0.window.remainingPercent < 5 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(isCritical ? .red : .orange)
                Text(entries.count > 1 ? "Limits almost gone" : entries[0].title + " almost gone")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }

            HStack {
                Button("Remind in 15 min", action: onSnooze)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(for entry: LimitAlertEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
            Text(detailLine(entry.window))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func detailLine(_ window: RateWindow) -> String {
        var parts = [String(format: "%.0f%% left", window.remainingPercent)]
        if let resetIn = window.timeUntilReset {
            parts.append("resets in \(formatDuration(resetIn))")
        }
        if let exhaustion = window.timeToExhaustion {
            parts.append("at this rate: ~\(formatDuration(exhaustion)) left")
        }
        return parts.joined(separator: " · ")
    }
}
