import Foundation
import RFFileSystem
import Synchronization

/// Crash safety for copies (DESIGN.md §5.7). Copies are written to a hidden temporary name in the
/// destination and renamed into place only when complete, so a partial copy never appears under
/// the real name. Each temporary path is recorded here before it's created and removed once it's
/// gone; after a crash or a kill, `recover()` deletes whatever is left.
public final class OperationJournal: Sendable {
    public static let shared = OperationJournal(store: .shared)

    private let store: AppSupportStore
    private let entries = Mutex<Set<String>>([])
    private static let file = "op-journal.json"

    /// Put Back records for items RealFinder trashed: path in the Trash → where it came from.
    /// `trashItem` also writes Finder's `.DS_Store` record, but asynchronously, and items trashed in
    /// quick succession lose theirs (found in M5), so this is the primary source.
    struct PutBackEntry: Codable, Sendable {
        var original: String
        var device: Int32
        var inode: UInt64
    }
    private let putBack = Mutex<[String: PutBackEntry]>([:])
    private static let putBackFile = "putback.json"
    /// Marker in temporary names: ".report.pdf.rfpartial-1A2B3C4D".
    public static let marker = ".rfpartial-"

    public init(store: AppSupportStore) {
        self.store = store
        entries.withLock { $0 = Set(store.load([String].self, from: Self.file) ?? []) }
        putBack.withLock { $0 = store.load([String: PutBackEntry].self, from: Self.putBackFile) ?? [:] }
    }

    /// Remembers where trashed items came from. Entries whose item has left the Trash are dropped.
    func recordTrashed(_ pairs: [OperationRequest.Pair]) {
        guard !pairs.isEmpty else { return }
        var new: [String: PutBackEntry] = [:]
        for pair in pairs {
            guard let st = FileOps.lstat(pair.to) else { continue }
            new[pair.to.path] = PutBackEntry(original: pair.from.path, device: st.st_dev, inode: st.st_ino)
        }
        let snapshot = putBack.withLock { all -> [String: PutBackEntry] in
            all.merge(new) { $1 }
            if all.count > 2_000 { all = all.filter { Self.matches($0.key, $0.value) } }
            return all
        }
        store.save(snapshot, to: Self.putBackFile)
    }

    /// Where Put Back should return `trashed`, if RealFinder trashed it (and it's the same item).
    public func putBackLocation(for trashed: URL) -> URL? {
        guard let entry = putBack.withLock({ $0[trashed.path] }), Self.matches(trashed.path, entry) else { return nil }
        return URL(fileURLWithPath: entry.original)
    }

    private static func matches(_ path: String, _ entry: PutBackEntry) -> Bool {
        guard let st = FileOps.lstat(URL(fileURLWithPath: path)) else { return false }
        return st.st_dev == entry.device && st.st_ino == entry.inode
    }

    /// A temporary sibling for `final` (same folder, so the final rename is atomic).
    public static func temporaryURL(for final: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        return final.deletingLastPathComponent().appendingPathComponent(".\(final.lastPathComponent)\(marker)\(token)")
    }

    func begin(_ temporary: URL) {
        let snapshot = entries.withLock { e -> [String] in
            e.insert(temporary.path)
            return Array(e)
        }
        store.save(snapshot, to: Self.file)
    }

    func end(_ temporary: URL) {
        let snapshot = entries.withLock { e -> [String] in
            e.remove(temporary.path)
            return Array(e)
        }
        store.save(snapshot, to: Self.file)
    }

    /// Removes temporary copies left by an interrupted run. Only paths carrying the marker are
    /// ever deleted. Returns the paths removed.
    @discardableResult
    public func recover() -> [String] {
        let leftovers = entries.withLock { e -> [String] in
            let all = Array(e)
            e.removeAll()
            return all
        }
        var removed: [String] = []
        for path in leftovers where (path as NSString).lastPathComponent.contains(Self.marker) {
            if FileManager.default.fileExists(atPath: path) {
                FileOps.removeTree(URL(fileURLWithPath: path))
                removed.append(path)
            }
        }
        store.save([String](), to: Self.file)
        return removed
    }

    var pending: [String] { entries.withLock { Array($0) } }
}
