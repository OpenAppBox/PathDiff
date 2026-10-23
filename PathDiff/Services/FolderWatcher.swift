//
//  FolderWatcher.swift
//  PathDiff
//

import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports changed paths in batches.
nonisolated final class FolderWatcher: @unchecked Sendable {
    /// Receives absolute, symlink-resolved paths. `requiresRescan` is set when FSEvents could
    /// not deliver precise events (dropped events, root moved) and a full rescan is needed.
    typealias Handler = @Sendable (_ paths: [String], _ requiresRescan: Bool) -> Void

    private let handler: Handler
    private let queue = DispatchQueue(label: "PathDiff.FolderWatcher", qos: .utility)
    /// Marks `queue`, so `stop()` can tell when it already runs there (see `stop()`).
    private let queueKey = DispatchSpecificKey<Void>()
    // Only mutated in `init` and in `stop()` while holding `queue`.
    private var stream: FSEventStreamRef?

    /// The file system's current event ID: a watcher started later with it also reports
    /// what changed in between (for example while a scan ran).
    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    init?(path: String, since eventID: UInt64? = nil, latency: TimeInterval = 0.3, handler: @escaping Handler) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // No kFSEventStreamCreateFlagWatchRoot: to notice the root itself moving it opens every
        // parent folder when the stream is created, on the main thread. A parent such as
        // ~/Documents can then wait on a privacy prompt (or a slow network volume) and hang the
        // window. A moved root shows up instead when the next scan can't find it.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (array as NSArray) as? [String] ?? []
            let rescanMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged
            )
            var requiresRescan = false
            for index in 0..<eventCount where eventFlags[index] & rescanMask != 0 {
                requiresRescan = true
            }
            watcher.handler(paths, requiresRescan)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            eventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }

        self.stream = stream
        queue.setSpecific(key: queueKey, value: ())
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
    }

    /// Stops delivery. Runs on the event queue so no callback can be in flight afterwards.
    ///
    /// The callback holds the watcher while it runs, so the last release (and `deinit`) can
    /// happen on the event queue itself. A `queue.sync` there would trap, so in that case the
    /// stream is stopped in place and only released once the current callback has returned.
    func stop() {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            self.stream = nil
            // Stopped and invalidated, so nothing else touches the stream before this runs.
            nonisolated(unsafe) let stopped = stream
            queue.async { FSEventStreamRelease(stopped) }
            return
        }
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// FSEvents reports fully resolved paths (e.g. `/private/var/...`), so roots are compared
    /// in the same form.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
