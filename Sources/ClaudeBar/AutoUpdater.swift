import Foundation
import AppKit

enum UpdateError: LocalizedError {
    case noAsset
    case extractFailed
    case appNotFound
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .noAsset: return "No downloadable asset in release"
        case .extractFailed: return "Failed to extract archive"
        case .appNotFound: return "ClaudeBar.app not found in archive"
        case .binaryNotFound: return "Binary not found in archive"
        }
    }
}

@MainActor
final class AutoUpdater: ObservableObject {
    static let currentVersion = "2.1.1"
    static let autoUpdateKey = "com.claudebar.autoUpdate"

    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var error: String?
    @Published var progress: String?

    private var timer: Timer?

    private static let repo = "Alexandr-Kravchuk/claude-session-manager"
    private static let checkInterval: TimeInterval = 6 * 3600

    init() {
        let auto = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        if auto {
            startPeriodicCheck()
        }
    }

    deinit { timer?.invalidate() }

    func checkForUpdates(autoInstall: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let remote = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName
            latestVersion = remote
            updateAvailable = Self.isNewer(remote: remote, local: Self.currentVersion)
            if updateAvailable && autoInstall {
                await performUpdate()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func performUpdate() async {
        guard !isUpdating else { return }
        isUpdating = true
        error = nil
        defer {
            if error != nil {
                isUpdating = false
                progress = nil
            }
        }

        do {
            let release = try await fetchLatestRelease()
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                throw UpdateError.noAsset
            }

            progress = "Downloading…"
            let zipURL = try await downloadAsset(asset.browserDownloadUrl)

            progress = "Extracting…"
            let extractDir = try extractZip(at: zipURL)

            progress = "Installing…"
            try installUpdate(from: extractDir)

            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: extractDir)

            progress = "Relaunching…"
            try? await Task.sleep(nanoseconds: 300_000_000)
            relaunch()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startPeriodicCheck() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates(autoInstall: true)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await checkForUpdates(autoInstall: true)
        }
    }

    func stopPeriodicCheck() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - GitHub API

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Download & Install

    private func downloadAsset(_ urlString: String) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(
            from: URL(string: urlString)!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBar-update.zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func extractZip(at zipURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBar-update")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-xk", zipURL.path, dir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw UpdateError.extractFailed }
        return dir
    }

    private func installUpdate(from extractDir: URL) throws {
        let fm = FileManager.default
        guard let appSrc = findApp(in: extractDir) else { throw UpdateError.appNotFound }
        let exec = ProcessInfo.processInfo.arguments[0]

        if exec.contains(".app/Contents/MacOS/") {
            let bundle = URL(fileURLWithPath: exec)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            try replaceWithBackup(source: appSrc, destination: bundle)
        } else {
            let newBinary = appSrc.appendingPathComponent("Contents/MacOS/ClaudeBar")
            guard fm.fileExists(atPath: newBinary.path) else { throw UpdateError.binaryNotFound }
            try replaceWithBackup(source: newBinary, destination: URL(fileURLWithPath: exec))
        }
    }

    private func replaceWithBackup(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".bak")
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: destination, to: backup)
        }
        do {
            try fm.moveItem(at: source, to: destination)
            try? fm.removeItem(at: backup)
        } catch {
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("ClaudeBar.app")
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        for item in contents {
            if item.lastPathComponent == "ClaudeBar.app" { return item }
            let nested = item.appendingPathComponent("ClaudeBar.app")
            if fm.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }

    // MARK: - Relaunch

    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let exec = ProcessInfo.processInfo.arguments[0]
        let cmd: String
        if exec.contains(".app/Contents/MacOS/") {
            let app = URL(fileURLWithPath: exec)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            cmd = "open '\(app)'"
        } else {
            cmd = "nohup '\(exec)' > /tmp/claudebar.log 2>&1 &"
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; \(cmd)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        NSApp.terminate(nil)
    }

    // MARK: - Version comparison

    static func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
