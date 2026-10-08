import CFastFS
import Foundation
import RFModel
import Synchronization

/// Parallel breadth-first walk of a directory tree with getattrlistbulk: the crawl search backend
/// (DESIGN.md §5.6). Doesn't descend into other volumes, symlinks, packages (unless asked) or
/// hidden folders (unless asked). Unreadable folders are skipped and counted.
public enum TreeWalker {
    public struct Options: Sendable {
        public var includeHidden = false
        public var includePackageContents = false
        /// Folders scanned in parallel. SSDs benefit from ~8; spinning and network disks from ~2.
        public var concurrency = 8

        public init(includeHidden: Bool = false, includePackageContents: Bool = false, concurrency: Int = 8) {
            self.includeHidden = includeHidden
            self.includePackageContents = includePackageContents
            self.concurrency = concurrency
        }
    }

    public struct Progress: Sendable {
        public var foldersScanned = 0
        public var foldersSkipped = 0
    }

    public enum Event: Sendable {
        /// Items that passed `nameFilter`, in batches.
        case items([FileItem])
        case progress(Progress)
    }

    /// Streams every item under `root` whose name passes `nameFilter`. The filter runs on raw names
    /// before a `FileItem` is built, so non-matching entries cost almost nothing.
    public static func walk(
        _ root: URL, options: Options = Options(), nameFilter: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let walk = Walk(root: root, options: options, nameFilter: nameFilter, continuation: continuation)
            continuation.onTermination = { _ in walk.cancelled.store(true, ordering: .relaxed) }
            walk.start()
        }
    }
}

private final class Walk: @unchecked Sendable {
    let options: TreeWalker.Options
    let nameFilter: @Sendable (String) -> Bool
    let continuation: AsyncStream<TreeWalker.Event>.Continuation
    let cancelled = Atomic<Bool>(false)

    private let condition = NSCondition()
    private var pending: [URL]       // guarded by condition
    private var active = 0           // workers currently scanning a folder
    private var finishedWorkers = 0
    private var progress = TreeWalker.Progress()
    private var lastProgress = DispatchTime.now().uptimeNanoseconds

    init(root: URL, options: TreeWalker.Options, nameFilter: @escaping @Sendable (String) -> Bool,
         continuation: AsyncStream<TreeWalker.Event>.Continuation) {
        self.options = options
        self.nameFilter = nameFilter
        self.continuation = continuation
        self.pending = [root]
    }

    func start() {
        let workers = max(1, options.concurrency)
        for _ in 0..<workers {
            DispatchQueue.global(qos: .userInitiated).async { self.work(workers: workers) }
        }
    }

    private func work(workers: Int) {
        let batcher = Batcher(continuation: continuation)
        while let dir = next() {
            scan(dir, batcher)
            batcher.flushIfStale()
            finishedScanning()
        }
        batcher.flush()
        condition.lock()
        finishedWorkers += 1
        let last = finishedWorkers == workers
        let finalProgress = progress
        condition.unlock()
        if last {
            continuation.yield(.progress(finalProgress))
            continuation.finish()
        }
    }

    /// Next folder to scan, or nil when the walk is done (nothing pending and nobody scanning).
    private func next() -> URL? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled.load(ordering: .relaxed) {
                condition.broadcast()
                return nil
            }
            if let dir = pending.popLast() {
                active += 1
                return dir
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    private func finishedScanning() {
        condition.lock()
        active -= 1
        progress.foldersScanned += 1
        let now = DispatchTime.now().uptimeNanoseconds
        let report = now - lastProgress > 250_000_000
        if report { lastProgress = now }
        let snapshot = progress
        condition.broadcast()
        condition.unlock()
        if report { continuation.yield(.progress(snapshot)) }
    }

    private func enqueue(_ dirs: [URL]) {
        guard !dirs.isEmpty else { return }
        condition.lock()
        pending.append(contentsOf: dirs)
        condition.broadcast()
        condition.unlock()
    }

    private func scan(_ dir: URL, _ batcher: Batcher) {
        final class Context {
            let walk: Walk
            let dir: URL
            let batcher: Batcher
            var subdirs: [URL] = []
            init(_ walk: Walk, _ dir: URL, _ batcher: Batcher) {
                self.walk = walk
                self.dir = dir
                self.batcher = batcher
            }
        }
        let ctx = Context(self, dir, batcher)
        let rc = rf_enumerate(dir.path, { entryPtr, raw in
            let ctx = Unmanaged<Context>.fromOpaque(raw!).takeUnretainedValue()
            let walk = ctx.walk
            if walk.cancelled.load(ordering: .relaxed) { return 1 }
            let e = entryPtr!.pointee
            guard e.error == 0, let cName = e.name else { return 0 }
            let name = String(cString: cName)
            let hidden = name.hasPrefix(".") || e.flags & ItemBuilder.UF_HIDDEN != 0
            if hidden && !walk.options.includeHidden { return 0 }

            var item: FileItem?
            if walk.nameFilter(name) {
                item = ItemBuilder.make(e, in: ctx.dir)
                if let item { ctx.batcher.add(item) }
            }
            if e.objtype == ItemBuilder.VDIR && e.ismountpoint == 0 {
                let isPackage = item?.flags.contains(.package)
                    ?? ItemBuilder.directoryType(ext: (name as NSString).pathExtension.lowercased(),
                                                 hasBundleBit: e.finderflags & ItemBuilder.kHasBundle != 0).conforms(to: .package)
                if !isPackage || walk.options.includePackageContents {
                    ctx.subdirs.append(ctx.dir.appendingPathComponent(name, isDirectory: true))
                }
            }
            return 0
        }, Unmanaged.passUnretained(ctx).toOpaque())
        withExtendedLifetime(ctx) {
            if rc != 0 && rc != ECANCELED {
                condition.lock()
                progress.foldersSkipped += 1
                condition.unlock()
            }
            enqueue(ctx.subdirs)
        }
    }
}

/// Per-worker batch of matches, yielded every ~50 ms or 500 items.
private final class Batcher {
    let continuation: AsyncStream<TreeWalker.Event>.Continuation
    private var items: [FileItem] = []
    private var last = DispatchTime.now().uptimeNanoseconds

    init(continuation: AsyncStream<TreeWalker.Event>.Continuation) { self.continuation = continuation }

    func add(_ item: FileItem) {
        items.append(item)
        let now = DispatchTime.now().uptimeNanoseconds
        if items.count >= 500 || now - last > 50_000_000 {
            flush()
            last = now
        }
    }

    /// So a slow trickle of matches still shows up promptly.
    func flushIfStale() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - last > 50_000_000 {
            flush()
            last = now
        }
    }

    func flush() {
        guard !items.isEmpty else { return }
        continuation.yield(.items(items))
        items.removeAll(keepingCapacity: true)
    }
}
