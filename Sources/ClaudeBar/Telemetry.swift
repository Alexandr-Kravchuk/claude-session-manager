import Foundation
import AppKit
import Aptabase

/// Only explicit UI events are sent. Credentials, quota data and local activity stay local.
enum Telemetry {
    static let enabledKey = "com.claudebar.telemetryEnabled"
    private static let consentKey = "com.claudebar.telemetryConsentAsked"
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: consentKey) && UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func requestConsentIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: consentKey) else { return }
        NSApp.activate(ignoringOtherApps: true)
        while true {
            let alert = NSAlert()
            alert.messageText = "Help improve ClaudeBar?"
            alert.informativeText = "Share anonymous usage statistics to help us understand which features and options are useful. This is optional. You can change your choice in the ClaudeBar menu at any time."
            alert.addButton(withTitle: "Share Usage Statistics")
            alert.addButton(withTitle: "Not Now")
            alert.addButton(withTitle: "What Is Collected?")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                showDetails()
                continue
            }
            UserDefaults.standard.set(response == .alertFirstButtonReturn, forKey: enabledKey)
            UserDefaults.standard.set(true, forKey: consentKey)
            return
        }
    }

    static func showDetails() {
        let alert = NSAlert()
        alert.messageText = "About Usage Statistics"
        alert.informativeText = """
        What we collect
        • App launches and app version.
        • Features you use: menu, Statistics, tabs, history range, Refresh and Update.
        • Options you change and whether you turn them on or off.
        • System metadata: OS version, device model and language. Aptabase may derive country from the connection.

        What we never collect
        • Claude tokens or credentials.
        • Prompts, conversations, project names or file contents.
        • Your Claude usage limits or local activity history.

        How it works
        • Events go to Aptabase in the European Union.
        • We do not send a name, email or persistent installation ID.
        • Turn off “Share anonymous usage statistics” in the menu to stop recording new events. Events already queued may still be delivered.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    static func start() {
        Aptabase.shared.initialize(appKey: "A-EU-8326369632", with: InitOptions(
            appVersion: AutoUpdater.currentVersion
        ))
        guard enabled else { return }
        Aptabase.shared.trackEvent("app_started")
        // Menu bar apps may never activate; flush explicitly rather than relying on
        // the SDK's application activation notification to start delivery.
        Aptabase.shared.flush()
    }

    static func feature(_ name: String, value: String = "") {
        guard enabled else { return }
        Aptabase.shared.trackEvent("feature_used", with: ["feature": name, "value": value])
        Aptabase.shared.flush()
    }

    static func setting(_ name: String, enabled: Bool) {
        guard Self.enabled else { return }
        Aptabase.shared.trackEvent("setting_changed", with: [
            "setting": name, "enabled": enabled ? "true" : "false"
        ])
        Aptabase.shared.flush()
    }
}
