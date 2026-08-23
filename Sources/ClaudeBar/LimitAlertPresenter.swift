import AppKit
import SwiftUI

/// One rate window that has crossed into "almost gone" territory, ready for display.
struct LimitAlertEntry: Identifiable {
    enum Scope: String { case session, weekly, scopedWeekly }

    var id: String { scope.rawValue }

    let scope: Scope
    let title: String
    let window: RateWindow
    let resetsAt: Date
}

/// Last-resort, impossible-to-miss escalation above the standard notification banner:
/// a focus-stealing window when a limit is genuinely about to run out. The banner
/// (NotificationManager) can be dismissed unseen or hidden behind a fullscreen app —
/// this doesn't let that happen.
@MainActor
final class LimitAlertPresenter: NSObject {
    static let enabledKey = "com.claudebar.limitDialogEnabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Below this remaining %, the 5-hour session window earns a dialog.
    static let sessionThreshold: Double = 10
    /// Below this remaining %, either weekly window (general or per-model) earns one.
    static let weeklyThreshold: Double = 5
    /// Mirrors Recommender.evalSession's own carve-out: a session this close to its own
    /// reset is about to fix itself, so the banner/menu bar deliberately stay calm. The
    /// dialog is a blunter, threshold-only instrument than Recommender, but it should
    /// still honor this one softening rule rather than alarm the user for nothing.
    private static let imminentResetWindow: TimeInterval = 15 * 60

    /// One outstanding dialog at a time. Unlike the old design, a later `evaluate()` that
    /// finds the panel already open UPDATES it in place with the full current set of
    /// still-qualifying entries, instead of replacing it with only the newest ones — so a
    /// scope that alerted first is never silently dropped just because another scope
    /// crossed its own threshold later.
    private var panel: NSPanel?

    private static func suppressKey(_ scope: LimitAlertEntry.Scope) -> String {
        "com.claudebar.limitDialogSuppressedUntil.\(scope.rawValue)"
    }

    /// Persisted (not in-memory) so both the "already shown, wait for reset" state and the
    /// "snoozed for 15 minutes" state survive a relaunch — an in-memory-only snooze used to
    /// get wiped by an app restart mid-snooze, immediately re-showing the dialog the user
    /// had just asked to defer.
    private func suppressedUntil(_ scope: LimitAlertEntry.Scope) -> Date? {
        let key = Self.suppressKey(scope)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: key))
    }

    private func suppress(_ scope: LimitAlertEntry.Scope, until: Date) {
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.suppressKey(scope))
    }

    func evaluate(_ snapshot: UsageSnapshot) {
        guard Self.isEnabled else { return }  // settingChanged(enabled:) already closes any open panel

        let qualifying = qualifyingEntries(for: snapshot)
        guard !qualifying.isEmpty else {
            if panel != nil { close() }  // every window recovered — nothing left to warn about
            return
        }

        // Suppressed-until-reset (already shown) or suppressed-until-snooze-expiry both read
        // the same persisted value; either way, "not suppressed right now" means newly crossed.
        let newlyCrossed = qualifying.filter { entry in
            guard let until = suppressedUntil(entry.scope) else { return true }
            return until <= Date()
        }
        // Nothing new and no panel open: stay quiet. Nothing new but a panel IS open: still
        // refresh its content below so the displayed percentages don't go stale while it sits.
        guard panel != nil || !newlyCrossed.isEmpty else { return }

        for entry in newlyCrossed {
            suppress(entry.scope, until: entry.resetsAt)
        }
        show(qualifying, stealFocus: !newlyCrossed.isEmpty)
    }

    /// All windows currently under their threshold, regardless of whether they've already
    /// been alerted on — this is what the dialog DISPLAYS. `evaluate` separately decides,
    /// from persisted suppression state, whether any of them are new enough to interrupt for.
    private func qualifyingEntries(for snapshot: UsageSnapshot) -> [LimitAlertEntry] {
        var specs: [(scope: LimitAlertEntry.Scope, title: String, window: RateWindow, threshold: Double)] =
            [(.session, "5-hour limit", snapshot.session, Self.sessionThreshold)]
        if let weekly = snapshot.weekly {
            specs.append((.weekly, "Weekly limit", weekly, Self.weeklyThreshold))
        }
        if let scoped = snapshot.scopedWeekly {
            let title = snapshot.scopedModelName.map { "Weekly \($0) limit" } ?? "Weekly model limit"
            specs.append((.scopedWeekly, title, scoped, Self.weeklyThreshold))
        }

        return specs.compactMap { spec in
            // A window with no known reset time can neither be dedup'd nor recovered from —
            // same guard as RateWindow.paceTier.
            guard spec.window.remainingPercent < spec.threshold, let resetsAt = spec.window.resetsAt else { return nil }
            if spec.scope == .session, resetsAt.timeIntervalSinceNow < Self.imminentResetWindow { return nil }
            return LimitAlertEntry(scope: spec.scope, title: spec.title, window: spec.window, resetsAt: resetsAt)
        }
    }

    /// Called when the user flips the settings toggle, so an already-open dialog doesn't
    /// linger on screen after they've explicitly asked to stop being interrupted.
    func settingChanged(enabled: Bool) {
        guard !enabled else { return }
        close()
    }

    private func show(_ entries: [LimitAlertEntry], stealFocus: Bool) {
        let view = LimitAlertView(
            entries: entries,
            onDismiss: { [weak self] in self?.close() },
            onSnooze: { [weak self] in self?.snooze(entries) }
        )
        let hosting = NSHostingView(rootView: view)
        // Let SwiftUI compute its own ideal size (the view fixes its width, hugs its height)
        // instead of a hand-rolled "120 + count*56" guess that couldn't account for wrapped
        // text or a long model name in the title.
        hosting.frame.size = hosting.fittingSize

        if let panel {
            panel.contentView = hosting
            panel.setContentSize(hosting.frame.size)
        } else {
            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.frame.size),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.title = "Claude Code Limit"
            newPanel.contentView = hosting
            newPanel.isReleasedWhenClosed = false
            newPanel.hidesOnDeactivate = false
            newPanel.level = .floating
            // Without this, the panel is invisible while another app is fullscreen — exactly
            // when the user is heads-down and most needs to see it.
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.center()
            // So a titlebar-close (bypassing the in-view Dismiss button) still clears `panel`
            // — otherwise a later evaluate() would think a dialog is still open and try to
            // update a window nothing is showing instead of creating a fresh one.
            newPanel.delegate = self
            panel = newPanel
        }

        guard stealFocus else { return }  // content-only refresh of an already-open dialog

        // Full interrupt: bring the app forward and make the panel key, per the chosen
        // "steal focus" behavior. orderFrontRegardless() is a belt-and-suspenders fallback —
        // activate(ignoringOtherApps:)'s focus-stealing has gotten less reliable on recent
        // macOS versions when triggered from a background timer rather than a user click, so
        // this guarantees the panel is at least visually on top even if full key/focus isn't.
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    private func close() {
        panel?.close()
        panel = nil
    }

    private func snooze(_ entries: [LimitAlertEntry]) {
        let until = Date().addingTimeInterval(15 * 60)
        for entry in entries {
            suppress(entry.scope, until: until)
        }
        close()
    }

    #if DEBUG
    /// Used only by UsageStore's CLAUDEBAR_FAKE_LIMIT verification hook, so a debug session
    /// doesn't leave fabricated suppression timestamps behind under the same persisted keys
    /// real alerts use.
    func clearDebugState() {
        for scope in [LimitAlertEntry.Scope.session, .weekly, .scopedWeekly] {
            UserDefaults.standard.removeObject(forKey: Self.suppressKey(scope))
        }
    }
    #endif
}

extension LimitAlertPresenter: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
