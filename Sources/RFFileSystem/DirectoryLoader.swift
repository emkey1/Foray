import CFastFS
import Foundation
import RFModel
import Synchronization

public struct FileSystemError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let path: String

    public init(code: Int32, path: String) {
        self.code = code
        self.path = path
    }

    public var isPermissionDenied: Bool { code == EACCES || code == EPERM }
    public var isMissing: Bool { code == ENOENT || code == ENOTDIR }

    public var errorDescription: String? {
        let name = (path as NSString).lastPathComponent
        if isPermissionDenied {
            return "You don't have permission to see the contents of “\(name)”."
        }
        if isMissing { return "“\(name)” can't be found." }
        return "Couldn't read “\(name)”: \(String(cString: strerror(code))) (\(code))."
    }
}

/// Lists directories with getattrlistbulk on per-volume queues (DESIGN.md §5.4), streaming
/// batches so large folders paint immediately.
public final class DirectoryLoader: Sendable {
    public static let shared = DirectoryLoader()

    private let queues = Mutex<[String: DispatchQueue]>([:])

    public init() {}

    /// One serial queue per volume, so a hung network mount stalls only its own loads.
    /// Keyed by mount path derived from the URL alone: no syscalls before we're on the queue.
    func queue(for url: URL) -> DispatchQueue {
        let components = url.standardizedFileURL.pathComponents
        let key = components.count >= 3 && components[1] == "Volumes" ? "/Volumes/\(components[2])" : "/"
        return queues.withLock { q in
            if let existing = q[key] { return existing }
            let new = DispatchQueue(label: "rf.io.\(key)", qos: .userInitiated)
            q[key] = new
            return new
        }
    }

    /// Streams the directory's items in batches: a small first batch, then roughly every 50 ms.
    public func load(_ directory: URL, firstBatch: Int = 200) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let state = LoadState(directory: directory, continuation: continuation, firstBatch: firstBatch)
            continuation.onTermination = { _ in state.cancelled.store(true, ordering: .relaxed) }
            queue(for: directory).async {
                let rc = rf_enumerate(directory.path, { entry, ctx in
                    let state = Unmanaged<LoadState>.fromOpaque(ctx!).takeUnretainedValue()
                    return state.add(entry!.pointee) ? 0 : 1
                }, Unmanaged.passUnretained(state).toOpaque())
                withExtendedLifetime(state) {
                    state.flush()
                    if rc == 0 || rc == ECANCELED {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: FileSystemError(code: rc, path: directory.path))
                    }
                }
            }
        }
    }

    /// Convenience: the whole directory at once.
    public func loadAll(_ directory: URL) async throws -> [FileItem] {
        var all: [FileItem] = []
        for try await batch in load(directory) { all.append(contentsOf: batch) }
        return all
    }

    /// Re-reads one item's attributes (after a change event). Nil if it no longer exists.
    public func stat(_ url: URL) -> FileItem? {
        final class Box {
            let directory: URL
            var item: FileItem?
            init(_ directory: URL) { self.directory = directory }
        }
        let box = Box(url.deletingLastPathComponent())
        let rc = rf_stat(url.path, { entry, ctx in
            let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
            box.item = ItemBuilder.make(entry!.pointee, in: box.directory)
            return 0
        }, Unmanaged.passUnretained(box).toOpaque())
        return rc == 0 ? box.item : nil
    }
}

/// Accumulates items on the I/O queue and yields batches.
private final class LoadState: @unchecked Sendable {
    let directory: URL
    let continuation: AsyncThrowingStream<[FileItem], Error>.Continuation
    let firstBatch: Int
    let cancelled = Atomic<Bool>(false)
    private var pending: [FileItem] = []
    private var yieldedAny = false
    private var lastYield = DispatchTime.now().uptimeNanoseconds

    init(directory: URL, continuation: AsyncThrowingStream<[FileItem], Error>.Continuation, firstBatch: Int) {
        self.directory = directory
        self.continuation = continuation
        self.firstBatch = firstBatch
    }

    /// Returns false to stop enumerating.
    func add(_ e: rf_entry) -> Bool {
        if cancelled.load(ordering: .relaxed) { return false }
        if let item = ItemBuilder.make(e, in: directory) { pending.append(item) }
        let now = DispatchTime.now().uptimeNanoseconds
        if (!yieldedAny && pending.count >= firstBatch) || (yieldedAny && now - lastYield > 50_000_000) {
            flush()
            lastYield = now
        }
        return true
    }

    func flush() {
        guard !pending.isEmpty else { return }
        continuation.yield(pending)
        pending.removeAll(keepingCapacity: true)
        yieldedAny = true
    }
}
