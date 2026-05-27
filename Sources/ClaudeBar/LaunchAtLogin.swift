import ServiceManagement
import Foundation

struct LaunchAtLogin {
    static var isEnabled: Bool {
        if Bundle.main.bundleIdentifier != nil {
            return SMAppService.mainApp.status == .enabled
        }
        return plistExists
    }

    static func enable() throws {
        if Bundle.main.bundleIdentifier != nil {
            try SMAppService.mainApp.register()
        } else {
            try enableViaPlist()
        }
    }

    static func disable() throws {
        if Bundle.main.bundleIdentifier != nil {
            try SMAppService.mainApp.unregister()
        } else {
            try disableViaPlist()
        }
    }

    // MARK: — Fallback: LaunchAgent plist (dev / plain binary)

    private static let label = "com.claudebar.app"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var plistExists: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func enableViaPlist() throws {
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": "/tmp/claudebar.log",
            "StandardErrorPath": "/tmp/claudebar.log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        try shell("/bin/launchctl", "load", plistURL.path)
    }

    private static func disableViaPlist() throws {
        guard plistExists else { return }
        try? shell("/bin/launchctl", "unload", plistURL.path)
        try FileManager.default.removeItem(at: plistURL)
    }

    private static func shell(_ exe: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }
}
