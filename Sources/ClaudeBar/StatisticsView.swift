import SwiftUI

/// The Statistics window: a thin wrapper that loads the data from disk/store and hands it to
/// `StatisticsContent` to draw. Keeping the drawing pure (no environment, no IO) makes the
/// charts renderable in isolation for testing.
struct StatisticsView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        StatisticsLiveContent(
            history: store.history,
            activity: store.activity,
            snapshot: store.snapshot,
            lastUpdated: store.lastUpdated
        )
    }
}

/// Observes the history store directly. A copy in `@State` only reflected the samples that
/// existed when the window opened, leaving the chart stale while the menubar kept updating.
private struct StatisticsLiveContent: View {
    @ObservedObject var history: UsageHistoryStore
    let activity: ActivityProfile
    let snapshot: UsageSnapshot?
    let lastUpdated: Date?

    var body: some View {
        StatisticsContent(
            activity: activity,
            samples: history.samples,
            snapshot: snapshot,
            lastUpdated: lastUpdated
        )
    }
}
