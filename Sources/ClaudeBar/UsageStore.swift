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
    private var retryTask: Task<Void, Never>?
    private var activityWatcher: ActivityWatcher?
    private var lastAttempt: Date?
    /// Consecutive 429 count. Drives the exponential backoff; reset to 0 on any success.
    private var rateLimitStreak = 0

    /// Which token source last returned 200, so the next fetch starts with it instead of
    /// always probing the desktop token first — saves the extra request while the desktop
    /// token is server-revoked (401) and we keep succeeding via the CLI keychain token.
    private enum TokenSource { case desktop, cli }
    private var preferredTokenSource: TokenSource?

    /// Backoff doubles with each consecutive 429 — 6 → 12 → 24 → 48 min, capped at 60 —
    /// instead of a flat 5 min. The old flat interval equalled the refresh cadence and
    /// livelocked: every refresh landed just as the window expired, re-probed the still-
    /// active server limit, and re-armed another 5 min, so it never cleared while the app
    /// ran. A base above the cadence plus exponential growth lets the window actually
    /// elapse between probes — even the first window (6 min) outlasts the 5-min timer.
    private static let rateLimitBackoffBase: TimeInterval = 6 * 60
    private static let rateLimitBackoffCap: TimeInterval = 60 * 60
    /// Stop counting consecutive 429s once the backoff has reached the cap (streak 5):
    /// further increments wouldn't change the wait, and this keeps the persisted counter
    /// small and the `1 <<` shift in rateLimitBackoff(forStreak:) safe from overflow.
    private static let maxRateLimitStreak = 6
    private static let staleThreshold: TimeInterval = 10 * 60
    /// Minimum gap between any two automatic fetches. Bounds every unforced path
    /// (timer, activity, retry) regardless of error state, so a sustained failure
    /// can't turn the 5s ActivityWatcher into an API hammer. Kept below the 60s
    /// scheduleRetry sleep so the token-expired retry is never swallowed by it.
    private static let minFetchInterval: TimeInterval = 45

    // Persisted across launches so a restart mid-window doesn't immediately re-probe.
    private static let rateLimitedUntilKey = "com.claudebar.rateLimitedUntil"
    private static let rateLimitStreakKey = "com.claudebar.rateLimitStreak"

    init() {
        loadPersistedRateLimit()
        // Skip the startup probe while a persisted backoff window is still active: probing
        // would hit the live limit and re-arm the backoff. Surface the remaining wait
        // instead; the timer probes once the window elapses.
        if let until = rateLimitedUntil, until > Date() {
            errorMessage = rateLimitedMessage(retryIn: until.timeIntervalSinceNow)
        } else {
            Task { await refresh() }
        }
        scheduleTimer()
        activityWatcher = ActivityWatcher { [weak self] in
            Task { [weak self] in await self?.refreshOnActivity() }
        }
    }

    deinit {
        timer?.invalidate()
        retryTask?.cancel()
    }

    /// ClaudeBar never refreshes OAuth tokens itself — it reads a token that something else
    /// keeps fresh: the Claude desktop app's encrypted token cache (primary) or the CLI's
    /// keychain token (fallback). See candidateTokens. We only read it and fetch usage.
    /// A manual Refresh (`force: true`) bypasses the usage-endpoint rate-limit backoff.
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }

        if !force {
            if let until = rateLimitedUntil, until > Date() {
                errorMessage = rateLimitedMessage(retryIn: until.timeIntervalSinceNow)
                return
            }
            // Throttle on last *attempt*, not last success — a frozen lastUpdated
            // during a sustained error must not let callers slip through.
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.minFetchInterval {
                return
            }
        }

        lastAttempt = Date()
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await fetchUsageTryingCandidates()
            // A 200 reached us, so we're no longer rate limited — reset the backoff even
            // if the body has no decodable session data.
            clearRateLimit()
            retryTask?.cancel()
            retryTask = nil
            if let snap = UsageSnapshot.from(response) {
                snapshot = snap
                lastUpdated = Date()
                errorMessage = nil
            } else {
                errorMessage = "No session data from API."
            }
        } catch APIError.unauthorized {
            errorMessage = APIError.unauthorized.errorDescription
        } catch APIError.rateLimited {
            // Only a 429 that starts a *new* window escalates the streak. A manual refresh
            // (force) probes inside an active window; counting those clicks would let the
            // user inflate their own backoff and make the displayed retry time dishonest.
            let now = Date()
            if let until = rateLimitedUntil, until > now {
                errorMessage = rateLimitedMessage(retryIn: until.timeIntervalSinceNow)
            } else {
                rateLimitStreak = min(rateLimitStreak + 1, Self.maxRateLimitStreak)
                let backoff = Self.rateLimitBackoff(forStreak: rateLimitStreak)
                rateLimitedUntil = now.addingTimeInterval(backoff)
                persistRateLimit()
                errorMessage = rateLimitedMessage(retryIn: backoff)
            }
        } catch APIError.tokenExpired {
            errorMessage = APIError.tokenExpired.errorDescription
            scheduleRetry()
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

    private func refreshOnActivity() async {
        guard retryTask == nil else { return }  // pending retry owns error recovery
        await refresh()  // refresh() self-throttles via lastAttempt, even on errors
    }

    /// The access tokens to try, in priority order: the token the Claude desktop app keeps
    /// continuously fresh in its own encrypted store (so we never refresh the rate-limited
    /// OAuth token endpoint ourselves), then the standalone CLI's keychain token. The
    /// desktop token's `expiresAt` reflects only its *local* clock — the server can revoke
    /// it early (e.g. a `claude login` rotates the session and kills the desktop token),
    /// after which it still looks valid here but returns 401. So we keep the CLI token as a
    /// live fallback instead of committing to the desktop token up front. De-duped, ordered.
    private func candidateTokens() -> [(source: TokenSource, token: String)] {
        var tokens: [(source: TokenSource, token: String)] = []
        if let desktop = DesktopTokenReader.currentToken() { tokens.append((.desktop, desktop)) }
        if let cli = try? KeychainReader.readCredentials().accessToken { tokens.append((.cli, cli)) }
        var seen = Set<String>()
        var deduped = tokens.filter { seen.insert($0.token).inserted }
        // Start with the source that last worked, so a server-revoked desktop token doesn't
        // cost a wasted 401 probe on every refresh once the CLI token is carrying us.
        if let pref = preferredTokenSource,
           let idx = deduped.firstIndex(where: { $0.source == pref }), idx != 0 {
            deduped.insert(deduped.remove(at: idx), at: 0)
        }
        return deduped
    }

    /// Fetch usage, trying each candidate token until one is accepted; remember the source
    /// that succeeded so the next fetch leads with it. Only an *auth* rejection (401) falls
    /// through to the next token — a 429 or network error is identical for every token, so it
    /// propagates immediately instead of being masked. With no token available at all,
    /// rethrow the keychain's own "run claude login" error.
    private func fetchUsageTryingCandidates() async throws -> OAuthUsageResponse {
        let tokens = candidateTokens()
        guard !tokens.isEmpty else {
            _ = try KeychainReader.readCredentials()   // throws .notFound → "run claude login"
            throw APIError.unauthorized
        }
        var authError = APIError.tokenExpired
        for candidate in tokens {
            do {
                let response = try await OAuthAPI.fetchUsage(accessToken: candidate.token)
                preferredTokenSource = candidate.source
                return response
            }
            catch APIError.tokenExpired { authError = .tokenExpired }
            catch APIError.unauthorized { authError = .unauthorized }
        }
        throw authError
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }  // already one pending — let it fire
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            self?.retryTask = nil   // clear before refresh so next failure can re-schedule
            await self?.refresh()
        }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    /// Exponential backoff for the Nth consecutive 429: 6, 12, 24, 48 min, capped at 60.
    /// `streak` is bounded by maxRateLimitStreak, so the shift can't overflow.
    private static func rateLimitBackoff(forStreak streak: Int) -> TimeInterval {
        let multiplier = TimeInterval(1 << max(streak - 1, 0))
        return min(rateLimitBackoffBase * multiplier, rateLimitBackoffCap)
    }

    private func rateLimitedMessage(retryIn interval: TimeInterval) -> String {
        "Rate limited — retry in \(formatDuration(interval))"
    }

    /// Clear the backoff after a successful fetch so the next limit starts at the base.
    private func clearRateLimit() {
        guard rateLimitedUntil != nil || rateLimitStreak != 0 else { return }
        rateLimitedUntil = nil
        rateLimitStreak = 0
        clearPersistedRateLimit()
    }

    private func persistRateLimit() {
        guard let until = rateLimitedUntil else { return }
        let defaults = UserDefaults.standard
        defaults.set(until.timeIntervalSince1970, forKey: Self.rateLimitedUntilKey)
        defaults.set(rateLimitStreak, forKey: Self.rateLimitStreakKey)
    }

    private func clearPersistedRateLimit() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.rateLimitedUntilKey)
        defaults.removeObject(forKey: Self.rateLimitStreakKey)
    }

    /// Restore a rate-limit window that outlived the previous process. If it already
    /// elapsed while we were closed, discard it so the next refresh probes normally.
    private func loadPersistedRateLimit() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.rateLimitedUntilKey) != nil else { return }
        let until = Date(timeIntervalSince1970: defaults.double(forKey: Self.rateLimitedUntilKey))
        guard until > Date() else {
            clearPersistedRateLimit()
            return
        }
        rateLimitedUntil = until
        rateLimitStreak = defaults.integer(forKey: Self.rateLimitStreakKey)
    }

    /// The "new pace UI" feature flag, shared with MenuView's @AppStorage. On by default.
    static let newPaceUIKey = "com.claudebar.newPaceUI"
    var newPaceUIEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.newPaceUIKey) as? Bool ?? true
    }

    var recommendation: Recommendation? {
        snapshot.map { Recommender(snapshot: $0, newPaceUI: newPaceUIEnabled).recommend() }
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
        let session = "5h \(Int(snap.session.remainingPercent.rounded()))%"
        // Weekly may be absent (e.g. older API shape); show session alone then.
        guard let weekly = snap.weekly else { return session }
        return "\(session) · 7d \(Int(weekly.remainingPercent.rounded()))%"
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
        // Headroom = blue: the menubar distinguishes "capacity going to waste"
        // from on-track green.
        if recommendation?.isHeadroom == true { return .blue }
        switch recommendation?.urgency {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        case nil: return .secondary
        }
    }
}
