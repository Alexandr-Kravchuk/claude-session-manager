import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory (not .prohibited): keeps ClaudeBar out of the Dock and app switcher
        // while still letting the Statistics window open and take focus when requested.
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        runFastBurnSegmentsSelfCheck()
        #endif
    }
}

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = UsageStore()
    @StateObject private var updater = AutoUpdater()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
                .environmentObject(updater)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.menuBarIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(store.statusColor)
                Text(store.menuBarText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)

        Window("Claude Code Statistics", id: StatisticsWindow.id) {
            StatisticsView()
                .environmentObject(store)
        }
        .windowResizability(.contentMinSize)
    }
}

enum StatisticsWindow {
    static let id = "statistics"
}
