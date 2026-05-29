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
    private var cachedToken: String?
    private var rateLimitedUntil: Date?

    private static let rateLimitBackoff: TimeInterval = 5 * 60

    init() {
        Task { await refresh() }
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() async {
        if let until = rateLimitedUntil {
            if until > Date() {
                let remaining = until.timeIntervalSinceNow
                errorMessage = "Rate limited — retrying in \(formatDuration(remaining))"
                return
            }
            rateLimitedUntil = nil
        }

        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let token = try await resolveToken()
            let response = try await OAuthAPI.fetchUsage(accessToken: token)
            if let snap = UsageSnapshot.from(response) {
                snapshot = snap
                lastUpdated = Date()
                errorMessage = nil
            } else {
                errorMessage = "No session data from API."
            }
        } catch APIError.rateLimited {
            rateLimitedUntil = Date().addingTimeInterval(Self.rateLimitBackoff)
            errorMessage = "Rate limited — retrying in \(formatDuration(Self.rateLimitBackoff))"
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func resolveToken() async throws -> String {
        if let cached = cachedToken { return cached }
        var credentials = try KeychainReader.readCredentials()

        if credentials.isExpired, let refreshToken = credentials.refreshToken {
            do {
                let refreshed = try await OAuthAPI.refreshToken(refreshToken)
                credentials = ClaudeCredentials(
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken ?? refreshToken,
                    expiresAt: refreshed.expiresAt,
                    rateLimitTier: credentials.rateLimitTier
                )
                cachedToken = refreshed.accessToken
            } catch {
                // Use the existing token anyway — it may still work
            }
        }
        return credentials.accessToken
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    var recommendation: Recommendation? {
        snapshot.map { Recommender(snapshot: $0).recommend() }
    }

    var menuBarText: String {
        guard let snap = snapshot else { return "C" }
        return "\(Int(snap.session.remainingPercent.rounded()))%"
    }

    var menuBarIcon: String {
        recommendation?.statusSymbol ?? "bolt.horizontal.circle"
    }

    var statusColor: Color {
        switch recommendation?.urgency {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        case nil: return .secondary
        }
    }
}
