import Foundation

/// One persisted observation of quota utilization. Appended on each successful refresh so
/// the Statistics window can chart how the 5-hour and weekly windows burn over time — data
/// the OAuth endpoint only ever exposes as a single current value, never as a history.
struct UsageSample: Codable {
    let t: Double            // epoch seconds
    let session: Double      // % of the 5-hour window used
    let weekly: Double?      // % of the weekly window used, if present
    let sonnet: Double?
    let opus: Double?

    var date: Date { Date(timeIntervalSince1970: t) }
}

/// Append-only log of `UsageSample`s at
/// ~/Library/Application Support/ClaudeBar/usage-history.jsonl. There is no retroactive
/// data — the quota-burn chart fills in as ClaudeBar keeps running.
@MainActor
final class UsageHistoryStore {
    private(set) var samples: [UsageSample] = []
    private let fileURL: URL

    /// Record at most one sample per this interval. Activity-driven refreshes can fire
    /// every ~45s; without this the log would bloat without adding any shape to the curve.
    private static let minRecordInterval: TimeInterval = 4 * 60
    /// Keep at most this much history; older samples are pruned when the file is loaded.
    private static let retention: TimeInterval = 30 * 86400

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage-history.jsonl")
        load()
    }

    /// Append a sample for this snapshot unless the previous one is too recent.
    func record(_ snapshot: UsageSnapshot) {
        if let last = samples.last,
           snapshot.fetchedAt.timeIntervalSince(last.date) < Self.minRecordInterval { return }
        let sample = UsageSample(
            t: snapshot.fetchedAt.timeIntervalSince1970,
            session: snapshot.session.usedPercent,
            weekly: snapshot.weekly?.usedPercent,
            sonnet: snapshot.sonnetWeekly?.usedPercent,
            opus: snapshot.opusWeekly?.usedPercent
        )
        samples.append(sample)
        append(sample)
    }

    func samples(since: Date) -> [UsageSample] { samples.filter { $0.date >= since } }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let decoder = JSONDecoder()
        var loaded: [UsageSample] = []
        var lineCount = 0
        for line in text.split(separator: "\n") {
            lineCount += 1
            guard let lineData = line.data(using: .utf8),
                  let sample = try? decoder.decode(UsageSample.self, from: lineData) else { continue }
            if sample.date >= cutoff { loaded.append(sample) }
        }
        samples = loaded.sorted { $0.t < $1.t }
        // Compact the file if we dropped expired or unparsable lines, keeping it bounded.
        if samples.count != lineCount { rewrite() }
    }

    private func append(_ sample: UsageSample) {
        guard let encoded = try? JSONEncoder().encode(sample),
              var line = String(data: encoded, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            // The file is genuinely absent (first write): create it. We only take this path
            // when the file does NOT exist — a transient open failure on an existing file
            // must not fall through to a single-line write that would truncate weeks of data.
            try? lineData.write(to: fileURL, options: .atomic)
        }
    }

    private func rewrite() {
        let encoder = JSONEncoder()
        let lines = samples
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        let blob = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        // Atomic: an interrupted write (crash/power loss mid-compaction) must never leave a
        // truncated or empty file in place of the accumulated history.
        try? blob.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
