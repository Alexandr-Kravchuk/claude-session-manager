import SwiftUI
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    private var timer: Timer?
    private var rateLimitedUntil: Date?

    private static let rateLimitBackoff: TimeInterval = 5 * 60
    private static let staleThreshold: TimeInterval = 10 * 60

    init() {
        Task { await refresh() }
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
    }

    /// ClaudeBar does not refresh OAuth tokens itself — the Claude Code CLI keeps the
    /// keychain token fresh while you use it. We only read that token and fetch usage.
    /// A manual Refresh (`force: true`) bypasses the usage-endpoint rate-limit backoff.
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }

        if !force, let until = rateLimitedUntil, until > Date() {
            errorMessage = "Rate limited — retry in \(formatDuration(until.timeIntervalSinceNow))"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let token = try resolveToken()
            let response = try await OAuthAPI.fetchUsage(accessToken: token)
            if let snap = UsageSnapshot.from(response) {
                snapshot = snap
                lastUpdated = Date()
                errorMessage = nil
                rateLimitedUntil = nil
            } else {
                errorMessage = "No session data from API."
            }
        } catch APIError.unauthorized {
            errorMessage = APIError.unauthorized.errorDescription
        } catch APIError.rateLimited {
            rateLimitedUntil = Date().addingTimeInterval(Self.rateLimitBackoff)
            errorMessage = "Rate limited — retry in \(formatDuration(Self.rateLimitBackoff))"
        } catch APIError.tokenExpired {
            errorMessage = APIError.tokenExpired.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh when the menu opens if data is older than ~60s, so the popover shows
    /// fresh numbers without polling the API aggressively in the background.
    func refreshIfStale() async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 60 { return }
        await refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try LaunchAtLogin.enable() }
            else { try LaunchAtLogin.disable() }
            launchAtLogin = LaunchAtLogin.isEnabled
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// Reads the access token the Claude Code CLI maintains in the keychain.
    /// We deliberately do NOT perform our own OAuth refresh: the refresh token is
    /// single-use and rotates, so competing with the CLI over the same keychain entry
    /// triggered daily 429s. A stale token surfaces as `.tokenExpired`, which prompts
    /// the user to open Claude Code (the CLI refreshes the token there).
    private func resolveToken() throws -> String {
        let credentials = try KeychainReader.readCredentials()
        guard !credentials.isExpired else {
            throw APIError.tokenExpired
        }
        return credentials.accessToken
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    var recommendation: Recommendation? {
        snapshot.map { Recommender(snapshot: $0).recommend() }
    }

    /// The displayed snapshot is older than the staleness threshold, so its
    /// numbers can no longer be trusted as current.
    var isStale: Bool {
        guard let lastUpdated else { return false }
        return Date().timeIntervalSince(lastUpdated) > Self.staleThreshold
    }

    /// We have data on screen but can't vouch for its freshness — show a warning
    /// rather than a confident health colour.
    var isDegraded: Bool {
        snapshot != nil && isStale
    }

    var menuBarText: String {
        guard let snap = snapshot else { return "C" }
        // Don't anchor on a stale percentage: an old session% for a window that has
        // since reset is exactly the kind of confident-but-wrong number we set out to fix.
        if isStale { return "—" }
        return "\(Int(snap.session.remainingPercent.rounded()))%"
    }

    var menuBarIcon: String {
        if snapshot == nil {
            return errorMessage == nil ? "bolt.horizontal.circle" : "exclamationmark.triangle.fill"
        }
        if isStale { return "exclamationmark.triangle.fill" }
        return recommendation?.statusSymbol ?? "bolt.horizontal.circle"
    }

    var statusColor: Color {
        if snapshot == nil || isStale { return .secondary }
        switch recommendation?.urgency {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        case nil: return .secondary
        }
    }
}
