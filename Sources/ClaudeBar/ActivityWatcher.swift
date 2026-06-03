import Foundation
import CoreServices

/// Watches ~/.claude/history.jsonl for writes.
/// Claude Code appends to this file whenever it processes a message, meaning
/// the OAuth token in the keychain is fresh at that moment. We use this as a
/// signal to refresh usage data without managing our own token refresh cycle.
final class ActivityWatcher {
    private var stream: FSEventStreamRef?
    private let onActivity: () -> Void

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        start()
    }

    deinit { stop() }

    private func start() {
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let paths = [claudeDir] as CFArray

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let cb: FSEventStreamCallback = { _, info, count, pathsPtr, _, _ in
            guard let info else { return }
            let me = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(pathsPtr).takeUnretainedValue() as NSArray
            for i in 0..<count {
                if let path = arr[i] as? String, path.hasSuffix("history.jsonl") {
                    me.onActivity()
                    return
                }
            }
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
