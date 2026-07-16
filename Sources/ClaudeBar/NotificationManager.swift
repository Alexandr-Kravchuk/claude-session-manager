import Foundation
import UserNotifications

/// Standard macOS notifications for when a usage limit needs attention. Edge-triggered off
/// the same Recommendation the menu already shows, so the banner can never disagree with the
/// popover. The whole point is to surface a limit the user isn't looking at — so it fires only
/// on the *rise* into an attention-worthy urgency, never repeatedly while it stays there.
@MainActor
final class NotificationManager {
    /// Notifications on by default; the menu exposes a checkbox bound to this key.
    static let enabledKey = "com.claudebar.notificationsEnabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// A single replaceable banner — a fresh alert supersedes the last in Notification Center
    /// rather than stacking, so the user always sees the current state, not a pile of history.
    private static let identifier = "com.claudebar.limitAlert"

    /// The urgency of the last banner we posted. We notify only when urgency climbs *above*
    /// this — a level that merely holds (e.g. staying critical for hours) is silent — and reset
    /// it once urgency falls back below the attention threshold, so the next real spike alerts
    /// again. `nil` means "nothing outstanding".
    private var lastNotifiedUrgency: Urgency?

    /// Only .high and .critical warrant interrupting the user. Everything below is routine and
    /// stays in the menu.
    private static let attentionThreshold: Urgency = .high

    private var authorized = false

    /// Ask once at launch. Denial is fine — we just never post, and `evaluate` short-circuits.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Called after every snapshot refresh. Decides — from the transition, not the level alone —
    /// whether this update deserves a banner.
    func evaluate(_ recommendation: Recommendation?) {
        guard Self.isEnabled, let recommendation else { return }
        let urgency = recommendation.urgency

        guard urgency >= Self.attentionThreshold else {
            // Back in calm territory — arm the next rise.
            lastNotifiedUrgency = nil
            return
        }

        // Already alerted at this level or higher; don't nag until it recovers and spikes anew.
        if let last = lastNotifiedUrgency, urgency <= last { return }

        lastNotifiedUrgency = urgency
        post(recommendation)
    }

    private func post(_ recommendation: Recommendation) {
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = recommendation.urgency == .critical ? "Claude Code limit exhausted" : "Claude Code limit running low"
        content.body = [recommendation.headline, recommendation.sessionLine, recommendation.weeklyLine, recommendation.modelLine]
            .compactMap { $0 }
            .prefix(3)
            .joined(separator: "\n")
        content.sound = .default
        // Critical wording earns a time-sensitive banner so it can break through a Focus filter;
        // "running low" stays a normal alert.
        if recommendation.urgency == .critical { content.interruptionLevel = .timeSensitive }

        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
