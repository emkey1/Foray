import CoreServices
import Foundation
import Synchronization

/// One shared FSEvents stream covering every directory currently on screen (DESIGN.md §5.4).
/// Subscribers register a directory and get called (on a background queue) when its contents
/// change. Adding a directory restarts the stream before `subscribe` returns, so callers can list
/// the directory afterwards without missing changes; removals are debounced. Restarts resume from
/// the last event ID seen, so no events fall into the gap.
public final class DirectoryWatcher: @unchecked Sendable {
    public static let shared = DirectoryWatcher()

    public struct Token: Hashable, Sendable { fileprivate let id: UInt64 }

    private struct Subscription {
        let path: String            // as given by the subscriber
        let canonical: String       // symlinks resolved, as FSEvents reports it
        let handler: @Sendable () -> Void
    }

    private let queue = DispatchQueue(label: "rf.fsevents", qos: .utility)
    private var subscriptions: [UInt64: Subscription] = [:]   // queue-confined
    private var nextID: UInt64 = 0
    private var stream: FSEventStreamRef?
    private var watchedPaths: Set<String> = []
    private var rebuildScheduled = false
    private var lastEventID: FSEventStreamEventId?   // nil until the first event
    private let latency: CFTimeInterval

    public init(latency: CFTimeInterval = 0.1) { self.latency = latency }

    /// Calls `handler` whenever the directory's contents change (or FSEvents asks for a rescan).
    public func subscribe(_ directory: URL, handler: @escaping @Sendable () -> Void) -> Token {
        let path = Self.normalize(directory.path)
        let canonical = Self.canonicalPath(directory.path)
        return queue.sync {
            nextID += 1
            subscriptions[nextID] = Subscription(path: path, canonical: canonical, handler: handler)
            rebuild()
            return Token(id: nextID)
        }
    }

    public func unsubscribe(_ token: Token) {
        queue.async {
            self.subscriptions[token.id] = nil
            self.scheduleRebuild()
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            rebuildScheduled = false
            rebuild()
        }
    }

    /// On `queue`.
    private func rebuild() {
        let wanted = Set(subscriptions.values.map(\.canonical))
        guard wanted != watchedPaths else { return }
        if let s = stream {
            let latest = FSEventStreamGetLatestEventId(s)
            if latest != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) { lastEventID = max(lastEventID ?? 0, latest) }
        }
        stopStream()
        watchedPaths = wanted
        if !wanted.isEmpty { startStream(Array(wanted)) }
    }

    private func startStream(_ paths: [String]) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIDs in
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info!).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            var events: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<count {
                events.append((paths[i], eventFlags[i]))
                // History-done markers carry no path change; don't let them move the cursor.
                if eventFlags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 {
                    watcher.lastEventID = max(watcher.lastEventID ?? 0, eventIDs[i])
                }
            }
            watcher.deliver(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            lastEventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// On `queue`. Directory-level events name the directory whose contents changed; FSEvents is
    /// recursive, so events for unwatched subdirectories are ignored unless a rescan is requested.
    private func deliver(_ events: [(String, FSEventStreamEventFlags)]) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        var fired = Set<UInt64>()
        for (rawPath, flags) in events {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let path = Self.normalize(rawPath)
            let rescan = flags & rescanFlags != 0
            for (id, sub) in subscriptions where !fired.contains(id) {
                let hit = sub.canonical == path || sub.path == path
                    || (rescan && (sub.canonical.hasPrefix(path + "/") || path == "/"))
                if hit {
                    fired.insert(id)
                    sub.handler()
                }
            }
        }
    }

    /// realpath(3), as FSEvents reports paths. (`URL.resolvingSymlinksInPath` deliberately strips
    /// "/private", so it doesn't match: /var/folders/… is reported as /private/var/folders/….)
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return normalize(path) }
        defer { free(resolved) }
        return normalize(String(cString: resolved))
    }

    static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
