import SwiftUI

/// The Statistics window: a thin wrapper that loads the data from disk/store and hands it to
/// `StatisticsContent` to draw. Keeping the drawing pure (no environment, no IO) makes the
/// charts renderable in isolation for testing.
struct StatisticsView: View {
    @EnvironmentObject var store: UsageStore
    @State private var activity: ActivityProfile = .empty
    @State private var samples: [UsageSample] = []

    var body: some View {
        StatisticsContent(activity: activity, samples: samples)
            .task { await reload() }
    }

    @MainActor
    private func reload() async {
        samples = store.history.samples
        // Parse history.jsonl off the main actor so opening the window never blocks the UI.
        activity = await Task.detached(priority: .utility) { ActivityHistory.load() }.value
    }
}
