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
    /// Marker in temporary names: ".report.pdf.rfpartial-1A2B3C4D".
    public static let marker = ".rfpartial-"

    public init(store: AppSupportStore) {
        self.store = store
        entries.withLock { $0 = Set(store.load([String].self, from: Self.file) ?? []) }
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
