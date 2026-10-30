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
            Image(nsImage: MenuBarLabel.render(store.menuBarItems))
        }
        .menuBarExtraStyle(.window)

        Window("Claude Code Statistics", id: StatisticsWindow.id) {
            StatisticsView()
                .environmentObject(store)
        }
        .windowResizability(.contentMinSize)
    }
}

/// MenuBarExtra keeps only the first Image and Text of its label, so a per-window
/// icon + text row has to reach the menubar as one pre-rendered image.
@MainActor
enum MenuBarLabel {
    static func render(_ items: [UsageStore.MenuBarItem]) -> NSImage {
        let content = HStack(spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 3) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13))
                    Text(item.text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }
        .foregroundColor(.black)
        .frame(height: 18)
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // Template: the menubar tints it for light/dark, like the system's own items.
        image.isTemplate = true
        return image
    }
}

enum StatisticsWindow {
    static let id = "statistics"
}
