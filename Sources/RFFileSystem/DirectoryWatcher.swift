import CoreServices
import Foundation

/// Watches the directories currently on screen with FSEvents (DESIGN.md §5.4). Each watched
/// directory has its own stream, shared by all subscribers to that directory, so adding or
/// removing one never restarts (and never replays history into) the others. The stream is
/// running before `subscribe` returns, so callers can list the directory afterwards without
/// missing changes.
public final class DirectoryWatcher: @unchecked Sendable {
    public static let shared = DirectoryWatcher()

    public struct Token: Hashable, Sendable { fileprivate let id: UInt64 }

    /// One FSEvents stream and its subscribers. Confined to `queue`.
    private final class Watch {
        let path: String         // canonical, as FSEvents reports it
        var stream: FSEventStreamRef?
        var handlers: [UInt64: @Sendable () -> Void] = [:]
        /// Recent relevant events ("path flags=0x…"), for diagnostics.
        var recent: [String] = []
        init(path: String) { self.path = path }
    }

    private let queue = DispatchQueue(label: "rf.fsevents", qos: .utility)
    private var watches: [String: Watch] = [:]
    private var pathForToken: [UInt64: String] = [:]
    private var nextID: UInt64 = 0
    private let latency: CFTimeInterval

    public init(latency: CFTimeInterval = 0.1) { self.latency = latency }

    /// Calls `handler` (on a background queue) whenever the directory's contents change, or when
    /// FSEvents says it may have missed changes.
    public func subscribe(_ directory: URL, handler: @escaping @Sendable () -> Void) -> Token {
        let path = Self.canonicalPath(directory.path)
        return queue.sync {
            nextID += 1
            let watch = watches[path] ?? {
                let w = Watch(path: path)
                watches[path] = w
                start(w)
                return w
            }()
            watch.handlers[nextID] = handler
            pathForToken[nextID] = path
            return Token(id: nextID)
        }
    }

    public func unsubscribe(_ token: Token) {
        queue.async { [self] in
            guard let path = pathForToken.removeValue(forKey: token.id), let watch = watches[path] else { return }
            watch.handlers[token.id] = nil
            if watch.handlers.isEmpty {
                stop(watch)
                watches[path] = nil
            }
        }
    }

    var watchedPathCount: Int { queue.sync { watches.count } }

    /// Identity of the stream watching `directory` (tests: streams must not be restarted).
    func streamIdentity(for directory: URL) -> UInt? {
        let path = Self.canonicalPath(directory.path)
        return queue.sync { watches[path]?.stream.map { UInt(bitPattern: $0) } }
    }

    func recentEvents(for directory: URL) -> [String] {
        let path = Self.canonicalPath(directory.path)
        return queue.sync { watches[path]?.recent ?? [] }
    }

    private func start(_ watch: Watch) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(watch).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            let watch = Unmanaged<Watch>.fromOpaque(info!).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            let rescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            // Directory-level events name the directory whose contents changed. FSEvents is
            // recursive; changes deeper down don't affect this listing unless a rescan is needed.
            let relevant = (0..<count).contains { i in
                eventFlags[i] & rescan != 0 || DirectoryWatcher.normalize(paths[i]) == watch.path
            }
            if relevant {
                for i in 0..<count where eventFlags[i] & rescan != 0 || DirectoryWatcher.normalize(paths[i]) == watch.path {
                    watch.recent.append("\(paths[i]) flags=0x\(String(eventFlags[i], radix: 16))")
                }
                if watch.recent.count > 20 { watch.recent.removeFirst(watch.recent.count - 20) }
                for handler in watch.handlers.values { handler() }
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(
            nil, callback, &context, [watch.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        watch.stream = s
    }

    private func stop(_ watch: Watch) {
        guard let s = watch.stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        watch.stream = nil
    }

    /// realpath(3), as FSEvents reports paths. (`URL.resolvingSymlinksInPath` deliberately strips
    /// "/private", so it doesn't match: /var/folders/… is reported as /private/var/folders/….)
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return normalize(path) }
        defer { free(resolved) }
        return normalize(String(cString: resolved))
    }

    static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
