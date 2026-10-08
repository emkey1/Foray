import Darwin
import Foundation
import RFFileSystem
import RFModel
import Synchronization

public struct JobProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case preparing, running, paused, waitingForAnswer, finished
    }
    public var phase: Phase = .preparing
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    public var itemsTotal = 0
    public var itemsDone = 0
    public var currentName = ""

    public var fraction: Double? {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if itemsTotal > 0 { return min(1, Double(itemsDone) / Double(itemsTotal)) }
        return nil
    }
}

/// Progress shared between a running job (writer) and the UI (reader).
final class ProgressBox: Sendable {
    private let state = Mutex(JobProgress())
    func update(_ body: (inout JobProgress) -> Void) { state.withLock { p in body(&p) } }
    var current: JobProgress { state.withLock { $0 } }
}

/// Pause and cancel, shared between the UI and a running job.
public final class JobControl: Sendable {
    let cancelled = Atomic<Bool>(false)
    let paused = Atomic<Bool>(false)

    public init() {}
    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public func pause() { paused.store(true, ordering: .relaxed) }
    public func resume() { paused.store(false, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
    public var isPaused: Bool { paused.load(ordering: .relaxed) }

    /// Blocks while paused. Returns false if cancelled.
    func checkpoint() -> Bool {
        while isPaused && !isCancelled { usleep(50_000) }
        return !isCancelled
    }
}

/// Runs one request. Blocking filesystem work happens on the job's own serial queue (never the
/// main thread, never the cooperative pool); conflict questions are awaited in between.
/// Test-only switches, read from the environment (used by rf-crash-probe to make a copy slow
/// enough to kill mid-way). Never set in normal use.
enum TestHooks {
    static let noClone = ProcessInfo.processInfo.environment["RF_TEST_NO_CLONE"] != nil
    static let slowCopy = ProcessInfo.processInfo.environment["RF_TEST_SLOW_COPY"] != nil
}

final class Execution: @unchecked Sendable {
    let request: OperationRequest
    let control: JobControl
    let progress: ProgressBox
    let journal: OperationJournal
    let ask: @Sendable (ConflictQuestion) async -> ConflictAnswer
    let trashItem: TrashFunction
    private let io = DispatchQueue(label: "rf.op", qos: .userInitiated)
    var result = OperationResult()
    private var applyToAll: ConflictResolution?

    init(_ request: OperationRequest, control: JobControl, progress: ProgressBox, journal: OperationJournal,
         trash: @escaping TrashFunction, ask: @escaping @Sendable (ConflictQuestion) async -> ConflictAnswer) {
        self.trashItem = trash
        self.request = request
        self.control = control
        self.progress = progress
        self.journal = journal
        self.ask = ask
    }

    func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in io.async { c.resume(returning: work()) } }
    }

    func update(_ change: (inout JobProgress) -> Void) { progress.update(change) }

    func fail(_ url: URL, _ code: Int32, _ action: String) {
        if code != 0 { result.errors.append(ItemError(url: url, code: code, action: action)) }
    }

    func run() async -> OperationResult {
        switch request {
        case .copy(let items, let dir): await transfer(items, to: dir, moving: false)
        case .move(let items, let dir): await transfer(items, to: dir, moving: true)
        case .duplicate(let items): await duplicate(items)
        case .trash(let items): await trash(items)
        case .delete(let items): await delete(items)
        case .rename(let item, let name): await rename(item, to: name)
        case .newFolder(let dir, let name, let moving): await newFolder(in: dir, name: name, moving: moving)
        case .restore(let pairs), .putBack(let pairs): await restore(pairs)
        case .makeAlias(let items, let dir): await makeAliases(items, in: dir)
        case .setAttributes(let list): await setAttributes(list)
        case .batchRename(let pairs): await batchRename(pairs)
        case .compress(let items): await compress(items)
        case .expand(let archives): await expand(archives)
        case .emptyTrash(let folders):
            var items: [URL] = []
            for folder in folders {
                let listing: Result<[URL], NSError> = await blocking {
                    do { return .success(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) } catch { return .failure(error as NSError) }
                }
                switch listing {
                case .success(let list): items += list
                case .failure(let error): fail(folder, Self.errno(of: error), "empty the Trash in")
                }
            }
            await delete(items)
        case .changeTags(let items, let add, let remove):
            await tag(items.map { url in { (current: [String]) in
                var tags = current.filter { name in !remove.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
                for name in add where !tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { tags.append(name) }
                return (url, tags)
            } })
        case .setTags(let list):
            await tag(list.map { a in { (_: [String]) in (a.url, a.tags) } })
        }
        update { $0.phase = .finished }
        return result
    }

    // MARK: Copy and move

    private func transfer(_ items: [URL], to dir: URL, moving: Bool) async {
        // Planning: sizes for progress and a free-space check (copies, and moves across disks).
        let needsCopy = items.filter { !moving || !FileOps.sameVolume($0, dir) }
        let totals = await blocking { needsCopy.reduce((bytes: Int64(0), items: 0)) { acc, url in
            let t = FileOps.treeSize(url)
            return (acc.bytes + t.bytes, acc.items + t.items)
        } }
        update {
            $0.bytesTotal = totals.bytes
            $0.itemsTotal = max(totals.items, items.count)
            $0.phase = .running
        }
        let clonable = needsCopy.allSatisfy { FileOps.sameVolume($0, dir) }
        if !clonable, let free = await blocking({ FileOps.availableCapacity(dir) }), totals.bytes > free {
            fail(dir, ENOSPC, moving ? "move items to" : "copy items to")
            return
        }

        for (index, item) in items.enumerated() {
            guard control.checkpoint() else { break }
            update { $0.currentName = item.lastPathComponent }
            if dir.standardizedFileURL.path == item.standardizedFileURL.path
                || dir.standardizedFileURL.path.hasPrefix(item.standardizedFileURL.path + "/") {
                fail(item, EINVAL, moving ? "move" : "copy")
                continue
            }
            let sameFolder = item.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
            if moving && sameFolder { continue }  // already there
            guard let name = await chooseName(for: item, in: dir, copyingInPlace: !moving && sameFolder,
                                               moreToCome: index < items.count - 1) else {
                if result.stopped { break } else { continue }
            }
            let target = dir.appendingPathComponent(name)
            if moving && FileOps.sameVolume(item, dir) {
                let rc = await blocking { FileOps.rename(item, to: target) }
                if rc == 0 {
                    result.record(.moved(.init(from: item, to: target)))
                    result.changedFolders.formUnion([item.deletingLastPathComponent(), dir])
                } else {
                    fail(item, rc, "move")
                }
                update { $0.itemsDone += 1 }
                continue
            }
            let errorsBefore = result.errors.count
            if let copied = await copyItem(item, to: target) {
                result.changedFolders.insert(dir)
                if moving {
                    // Remove the original only if every part of it was copied.
                    if result.errors.count == errorsBefore {
                        let rc = await blocking { FileOps.remove(item) }
                        if rc == 0 {
                            result.record(.moved(.init(from: item, to: copied)))
                            result.changedFolders.insert(item.deletingLastPathComponent())
                        } else {
                            fail(item, rc, "remove the original of")
                            result.record(.created(copied))
                        }
                    } else {
                        result.record(.created(copied))
                    }
                } else {
                    result.record(.created(copied))
                }
            }
        }
    }

    /// The name an incoming item gets in `dir`, asking about conflicts. Nil to skip it.
    private func chooseName(for item: URL, in dir: URL, copyingInPlace: Bool, moreToCome: Bool) async -> String? {
        let name = item.lastPathComponent
        let target = dir.appendingPathComponent(name)
        let isTaken: @Sendable (String) -> Bool = { FileOps.exists(dir.appendingPathComponent($0)) }
        if copyingInPlace {
            // Paste into the same folder makes a copy, like Finder ("report copy.pdf").
            return await blocking { FileNaming.duplicateName(for: name, isTaken: isTaken) }
        }
        guard await blocking({ FileOps.exists(target) }) else { return name }

        let resolution: ConflictResolution
        if let all = applyToAll {
            resolution = all
        } else {
            let question = await blocking { () -> ConflictQuestion in
                let a = FileOps.lstat(item), b = FileOps.lstat(target)
                func date(_ s: stat?) -> Date? { s.map { Date(timeIntervalSince1970: TimeInterval($0.st_mtimespec.tv_sec)) } }
                return ConflictQuestion(
                    incoming: item, existing: target, incomingIsFolder: a.map(FileOps.isDirectory) ?? false,
                    existingIsFolder: b.map(FileOps.isDirectory) ?? false, incomingModified: date(a),
                    existingModified: date(b), moreToCome: moreToCome)
            }
            update { $0.phase = .waitingForAnswer }
            let answer = await ask(question)
            update { $0.phase = .running }
            resolution = answer.resolution
            if answer.applyToAll { applyToAll = resolution }
        }

        switch resolution {
        case .skip:
            return nil
        case .stop:
            result.stopped = true
            control.cancel()
            return nil
        case .keepBoth:
            return await blocking { FileNaming.keepBothName(for: name, isTaken: isTaken) }
        case .replace:
            // Never replace something that contains the incoming item (that would trash the source).
            if item.standardizedFileURL.path.hasPrefix(target.standardizedFileURL.path + "/") {
                fail(item, EINVAL, "replace with")
                return nil
            }
            // The existing item goes to the Trash, so Replace can be undone.
            let trashItem = self.trashItem
            let outcome: Result<URL, NSError> = await blocking {
                do { return .success(try trashItem(target)) } catch { return .failure(error as NSError) }
            }
            switch outcome {
            case .success(let trashedAt):
                result.record(.trashed(.init(from: target, to: trashedAt)))
                return name
            case .failure(let error):
                fail(target, Self.errno(of: error), "replace")
                return nil
            }
        }
    }

    /// Copies a file or tree to a temporary sibling of `target`, then renames it into place.
    private func copyItem(_ item: URL, to target: URL) async -> URL? {
        let temp = OperationJournal.temporaryURL(for: target)
        journal.begin(temp)
        defer { journal.end(temp) }
        let size = await blocking { FileOps.treeSize(item) }

        // Same APFS volume: clone the whole tree in one call (instant, metadata included).
        var rc = await blocking {
            !TestHooks.noClone && FileOps.sameVolume(item, target.deletingLastPathComponent()) ? FileOps.clone(item, to: temp) : ENOTSUP
        }
        if rc == 0 {
            update {
                $0.bytesDone += size.bytes
                $0.itemsDone += size.items
            }
        } else {
            rc = await blocking {
                if FileOps.exists(temp) { FileOps.removeTree(temp) }  // never build on a partial clone
                return self.copyTree(item, to: temp)
            }
        }
        if !control.checkpoint() || rc == ECANCELED {
            await blocking { FileOps.removeTree(temp) }
            return nil
        }
        if rc != 0 {
            fail(item, rc, "copy")
            await blocking { FileOps.removeTree(temp) }
            return nil
        }
        // Into place. If the name was taken meanwhile, keep both rather than overwrite.
        var final = target
        var renameRC = await blocking { FileOps.rename(temp, to: target) }
        if renameRC == EEXIST {
            let dir = target.deletingLastPathComponent()
            let other = dir.appendingPathComponent(FileNaming.keepBothName(for: target.lastPathComponent) {
                FileOps.exists(dir.appendingPathComponent($0))
            })
            final = other
            renameRC = await blocking { FileOps.rename(temp, to: other) }
        }
        if renameRC != 0 {
            fail(item, renameRC, "copy")
            await blocking { FileOps.removeTree(temp) }
            return nil
        }
        return final
    }

    /// Recursive copy with per-item errors (recorded, not fatal) and byte progress. Returns
    /// 0, ECANCELED, or the errno if the top-level item itself failed.
    private func copyTree(_ src: URL, to dst: URL) -> Int32 {
        guard control.checkpoint() else { return ECANCELED }
        guard let st = FileOps.lstat(src) else { return Darwin.errno }
        if FileOps.isDirectory(st) {
            let rc = FileOps.makeDirectory(dst, mode: 0o700)
            guard rc == 0 else { return rc }
            update { $0.itemsDone += 1 }
            let children = (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []
            for child in children {
                let crc = copyTree(src.appendingPathComponent(child), to: dst.appendingPathComponent(child))
                if crc == ECANCELED { return ECANCELED }
                if crc != 0 { fail(src.appendingPathComponent(child), crc, "copy") }
            }
            _ = FileOps.copyDirectoryMetadata(src, to: dst)  // after contents, so dates stick
            return 0
        }
        var reported: Int64 = 0
        let rc = FileOps.copyFile(src, to: dst) { copied in
            if TestHooks.slowCopy { usleep(20_000) }
            self.update { $0.bytesDone += copied - reported }
            reported = copied
            return self.control.checkpoint()
        }
        if rc == 0 {
            let remaining = Int64(st.st_size) - reported
            update {
                $0.bytesDone += max(0, remaining)
                $0.itemsDone += 1
            }
        }
        return rc
    }

    // MARK: Other operations

    private func duplicate(_ items: [URL]) async {
        update {
            $0.itemsTotal = items.count
            $0.phase = .running
        }
        for item in items {
            guard control.checkpoint() else { break }
            let dir = item.deletingLastPathComponent()
            update { $0.currentName = item.lastPathComponent }
            let name = await blocking { FileNaming.duplicateName(for: item.lastPathComponent) { FileOps.exists(dir.appendingPathComponent($0)) } }
            if let copy = await copyItem(item, to: dir.appendingPathComponent(name)) {
                result.record(.created(copy))
                result.changedFolders.insert(dir)
            }
        }
    }

    private func trash(_ items: [URL]) async {
        update {
            $0.itemsTotal = items.count
            $0.phase = .running
        }
        for item in items {
            guard control.checkpoint() else { break }
            update { $0.currentName = item.lastPathComponent }
            let trashItem = self.trashItem
            let outcome: Result<URL, NSError> = await blocking {
                do { return .success(try trashItem(item)) } catch { return .failure(error as NSError) }
            }
            switch outcome {
            case .success(let at):
                result.record(.trashed(.init(from: item, to: at)))
                result.changedFolders.insert(item.deletingLastPathComponent())
            case .failure(let error):
                fail(item, Self.errno(of: error), "move to the Trash")
            }
            update { $0.itemsDone += 1 }
        }
    }

    private func delete(_ items: [URL]) async {
        update {
            $0.itemsTotal = items.count
            $0.phase = .running
        }
        for item in items {
            guard control.checkpoint() else { break }
            update { $0.currentName = item.lastPathComponent }
            let rc = await blocking { FileOps.remove(item) }
            if rc == 0 {
                result.deleted.append(item)
                result.changedFolders.insert(item.deletingLastPathComponent())
            } else {
                fail(item, rc, "delete")
            }
            update { $0.itemsDone += 1 }
        }
    }

    private func rename(_ item: URL, to name: String) async {
        update { $0.phase = .running }
        if FileNaming.problem(with: name) != nil {
            fail(item, EINVAL, "rename")
            return
        }
        let target = item.deletingLastPathComponent().appendingPathComponent(name)
        guard target.lastPathComponent != item.lastPathComponent else { return }
        let rc = await blocking { FileOps.rename(item, to: target) }
        if rc == 0 {
            result.record(.moved(.init(from: item, to: target)))
            result.changedFolders.insert(item.deletingLastPathComponent())
        } else {
            fail(item, rc, "rename")
        }
    }

    private func newFolder(in dir: URL, name: String?, moving: [URL]) async {
        update { $0.phase = .running }
        let folderName = await blocking {
            FileNaming.newFolderName(base: name ?? "untitled folder") { FileOps.exists(dir.appendingPathComponent($0)) }
        }
        let folder = dir.appendingPathComponent(folderName, isDirectory: true)
        let rc = await blocking { FileOps.makeDirectory(folder) }
        guard rc == 0 else { return fail(folder, rc, "create") }
        result.record(.created(folder))
        result.changedFolders.insert(dir)
        for item in moving {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            let mrc = await blocking { FileOps.rename(item, to: target) }
            if mrc == 0 { result.record(.moved(.init(from: item, to: target))) } else { fail(item, mrc, "move") }
        }
    }

    /// Each closure gets an item's current tags and returns the item and its new tags.
    private func tag(_ changes: [@Sendable ([String]) -> (URL, [String])]) async {
        update {
            $0.itemsTotal = changes.count
            $0.phase = .running
        }
        for change in changes {
            guard control.checkpoint() else { break }
            let outcome: (URL, [String], [String], Int32) = await blocking {
                let probe = change([])
                let current = Tags.names(at: probe.0)
                let (url, new) = change(current)
                if new == current { return (url, current, new, 0) }
                return (url, current, new, Tags.write(new, to: url))
            }
            let (url, before, after, rc) = outcome
            if rc == 0 {
                if before != after {
                    result.record(.tagged(url, before: before, after: after))
                    result.changedFolders.insert(url.deletingLastPathComponent())
                }
            } else {
                fail(url, rc, "tag")
            }
            update { $0.itemsDone += 1 }
        }
    }

    /// Two phases: every item to a temporary name, then each to its new name, so names can be
    /// swapped or rotated. Each step is logged, so undo replays them backwards.
    private func batchRename(_ pairs: [OperationRequest.Pair]) async {
        update {
            $0.itemsTotal = pairs.count
            $0.phase = .running
        }
        var staged: [(pair: OperationRequest.Pair, temp: URL)] = []
        for pair in pairs where pair.from.standardizedFileURL != pair.to.standardizedFileURL {
            let temp = pair.from.deletingLastPathComponent().appendingPathComponent(".rfrename-\(UUID().uuidString.prefix(8))-\(pair.from.lastPathComponent)")
            let rc = await blocking { FileOps.rename(pair.from, to: temp) }
            if rc == 0 {
                result.record(.moved(.init(from: pair.from, to: temp)))
                staged.append((pair, temp))
            } else {
                fail(pair.from, rc, "rename")
            }
        }
        for (pair, temp) in staged {
            update { $0.currentName = pair.to.lastPathComponent }
            let rc = await blocking { FileOps.rename(temp, to: pair.to) }
            if rc == 0 {
                result.record(.moved(.init(from: temp, to: pair.to)))
            } else {
                // Taken after all (e.g. by an item outside the batch): put it back as it was.
                let back = await blocking { FileOps.rename(temp, to: pair.from) }
                if back == 0 { result.record(.moved(.init(from: temp, to: pair.from))) }
                fail(pair.from, rc, "rename")
            }
            result.changedFolders.insert(pair.to.deletingLastPathComponent())
            update { $0.itemsDone += 1 }
        }
    }

    private func setAttributes(_ list: [OperationRequest.AttributeAssignment]) async {
        update {
            $0.itemsTotal = list.count
            $0.phase = .running
        }
        for change in list {
            guard control.checkpoint() else { break }
            update { $0.currentName = change.url.lastPathComponent }
            let (before, rc) = await blocking {
                let before = ItemAttributes.read(change.url, fields: change.attributes)
                return (before, ItemAttributes.write(change.attributes, to: change.url))
            }
            if rc == 0 {
                if before != change.attributes {
                    result.record(.attributes(change.url, before: before, after: change.attributes))
                    result.changedFolders.insert(change.url.deletingLastPathComponent())
                }
            } else {
                fail(change.url, rc, "change")
            }
            update { $0.itemsDone += 1 }
        }
    }

    private func restore(_ pairs: [OperationRequest.Pair]) async {
        update {
            $0.itemsTotal = pairs.count
            $0.phase = .running
        }
        for pair in pairs {
            guard control.checkpoint() else { break }
            update { $0.currentName = pair.to.lastPathComponent }
            let parent = pair.to.deletingLastPathComponent()
            if await blocking({ !FileOps.exists(pair.from) }) {
                fail(pair.from, ENOENT, "restore")
                continue
            }
            if await blocking({ FileOps.exists(pair.to) && !FileOps.sameFile(pair.from, pair.to) }) {
                fail(pair.to, EEXIST, "restore")
                continue
            }
            // Put Back recreates a deleted parent folder, like Finder.
            _ = await blocking { try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
            if await blocking({ FileOps.sameVolume(pair.from, parent) }) {
                let rc = await blocking { FileOps.rename(pair.from, to: pair.to) }
                if rc == 0 { result.record(.moved(pair)) } else { fail(pair.from, rc, "restore") }
            } else if let copied = await copyItem(pair.from, to: pair.to) {
                let rc = await blocking { FileOps.remove(pair.from) }
                if rc == 0 { result.record(.moved(.init(from: pair.from, to: copied))) } else { result.record(.created(copied)) }
            }
            result.changedFolders.formUnion([pair.from.deletingLastPathComponent(), parent])
            update { $0.itemsDone += 1 }
        }
    }

    static func errno(of error: NSError) -> Int32 {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return ENOENT
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return EACCES
        case NSFileWriteVolumeReadOnlyError: return EROFS
        case NSFileWriteOutOfSpaceError: return ENOSPC
        default: return EIO
        }
    }
}
