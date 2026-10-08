import Foundation
import Synchronization
import UniformTypeIdentifiers

public struct ItemGroup: Hashable, Sendable {
    public let title: String
    public let range: Range<Int>
}

/// Filtered, sorted and grouped items: what every view mode renders (DESIGN.md §5.3).
public struct ItemSnapshot: Sendable {
    public let items: [FileItem]
    /// Empty when the arrangement has no grouping.
    public let groups: [ItemGroup]
    public let generation: Int
    /// Items in the source, including those hidden by the arrangement's filters.
    public let totalCount: Int
    private let indexByID: [FileID: Int]

    public init(items: [FileItem], groups: [ItemGroup] = [], generation: Int = 0, totalCount: Int? = nil) {
        self.items = items
        self.groups = groups
        self.generation = generation
        self.totalCount = totalCount ?? items.count
        var index = [FileID: Int](minimumCapacity: items.count)
        for (i, item) in items.enumerated() { index[item.id] = i }
        self.indexByID = index
    }

    public static let empty = ItemSnapshot(items: [])

    public func index(of id: FileID) -> Int? { indexByID[id] }
    public func item(_ id: FileID) -> FileItem? { indexByID[id].map { items[$0] } }
}

/// Localized kind strings, cached per type.
public enum KindNames {
    private static let cache = Mutex<[String: String]>([:])

    public static func name(for item: FileItem) -> String {
        if item.isNavigableFolder { return "Folder" }
        let id = item.contentType.identifier
        if let hit = cache.withLock({ $0[id] }) { return hit }
        let name = item.contentType.localizedDescription ?? (item.pathExtension.isEmpty ? "Document" : item.pathExtension.uppercased() + " File")
        cache.withLock { $0[id] = name }
        return name
    }
}

public enum ArrangementEngine {
    /// Pure function: filter → sort → group. Runs off the main thread.
    public static func arrange(
        _ source: [FileItem], with arrangement: Arrangement, kinds: KindCatalog = .shared,
        now: Date = Date(), calendar: Calendar = .current, generation: Int = 0
    ) -> ItemSnapshot {
        let visible = source.filter { item in
            (arrangement.showHidden || !item.flags.contains(.hidden))
                && kinds.matches(item, anyOf: arrangement.kindFilter)
        }
        let plan = SortPlan(visible, arrangement)

        guard let groupKey = arrangement.groupBy else {
            let order = plan.sortedIndices(Array(0..<Int32(visible.count)))
            return ItemSnapshot(items: order.map { visible[Int($0)] }, generation: generation, totalCount: source.count)
        }

        var buckets: [GroupBucket: [Int32]] = [:]
        for (i, item) in visible.enumerated() {
            buckets[GroupBucket.of(item, by: groupKey, now: now, calendar: calendar), default: []].append(Int32(i))
        }
        var items: [FileItem] = []
        items.reserveCapacity(visible.count)
        var groups: [ItemGroup] = []
        for bucket in buckets.keys.sorted() {
            let start = items.count
            items.append(contentsOf: plan.sortedIndices(buckets[bucket]!).map { visible[Int($0)] })
            groups.append(ItemGroup(title: bucket.title, range: start..<items.count))
        }
        return ItemSnapshot(items: items, groups: groups, generation: generation, totalCount: source.count)
    }

    /// Precomputed sort columns (decorate-sort-undecorate): each item's values for the active keys
    /// are computed once, string-valued keys (kind, extension, folder) become ranks, and indices
    /// are sorted instead of FileItem structs. Re-sorting 100k items went from 0.65–1.8 s to well
    /// under the 300 ms budget (DESIGN.md §5.13). Same order as `comparator(for:)`.
    struct SortPlan {
        enum Column {
            case numeric([Double], ascending: Bool)   // NaN = missing (sorts last either way)
            case name(ascending: Bool)
        }

        let items: [FileItem]
        let foldersFirst: [Bool]?
        let columns: [Column]

        init(_ items: [FileItem], _ arrangement: Arrangement) {
            self.items = items
            foldersFirst = arrangement.foldersFirst ? items.map(\.isNavigableFolder) : nil
            columns = arrangement.sort.compactMap { d in
                switch d.key {
                case .name: return .name(ascending: d.ascending)
                case .size:
                    return .numeric(items.map { $0.isNavigableFolder ? .nan : $0.size.map(Double.init) ?? .nan }, ascending: d.ascending)
                case .dateModified: return .numeric(items.map { $0.modified?.timeIntervalSince1970 ?? .nan }, ascending: d.ascending)
                case .dateCreated: return .numeric(items.map { $0.created?.timeIntervalSince1970 ?? .nan }, ascending: d.ascending)
                case .dateAdded: return .numeric(items.map { $0.added?.timeIntervalSince1970 ?? .nan }, ascending: d.ascending)
                case .dateLastOpened: return .numeric(items.map { $0.lastOpened?.timeIntervalSince1970 ?? .nan }, ascending: d.ascending)
                case .kind:
                    return .numeric(Self.ranks(items.map(KindNames.name(for:))) { $0.localizedStandardCompare($1) == .orderedAscending },
                                    ascending: d.ascending)
                case .fileExtension:
                    return .numeric(Self.ranks(items.map(\.pathExtension)) { $0.compare($1) == .orderedAscending }, ascending: d.ascending)
                case .folder:
                    return .numeric(Self.ranks(items.map { $0.url.deletingLastPathComponent().path }) {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }, ascending: d.ascending)
                case .tags, .manual:
                    return nil  // lazy attributes arrive later
                }
            }
        }

        /// Each value's position among the distinct values (few distinct values, so sorting them is cheap).
        static func ranks(_ values: [String], by less: (String, String) -> Bool) -> [Double] {
            let order = Array(Set(values)).sorted(by: less)
            var rank: [String: Double] = [:]
            for (i, v) in order.enumerated() { rank[v] = Double(i) }
            return values.map { rank[$0]! }
        }

        func less(_ i: Int, _ j: Int) -> Bool {
            if let f = foldersFirst, f[i] != f[j] { return f[i] }
            for column in columns {
                switch column {
                case .name(let ascending):
                    let c = items[i].sortKey.compare(items[j].sortKey)
                    if c != 0 { return ascending ? c < 0 : c > 0 }
                case .numeric(let values, let ascending):
                    let x = values[i], y = values[j]
                    let xMissing = x.isNaN, yMissing = y.isNaN
                    if xMissing != yMissing { return yMissing }
                    if !xMissing && x != y { return ascending ? x < y : x > y }
                }
            }
            let c = items[i].sortKey.compare(items[j].sortKey)
            if c != 0 { return c < 0 }
            let a = items[i].id, b = items[j].id
            return a.device != b.device ? a.device < b.device : a.inode < b.inode
        }

        func sortedIndices(_ indices: [Int32]) -> [Int32] {
            indices.sorted { less(Int($0), Int($1)) }
        }
    }

    /// Comparator for the arrangement: folders first (optional), then each sort descriptor, then
    /// name, then FileID, so the order is total and stable across runs.
    public static func comparator(for arrangement: Arrangement) -> (FileItem, FileItem) -> Bool {
        let descriptors = arrangement.sort.filter { $0.key != .manual }
        let foldersFirst = arrangement.foldersFirst
        return { a, b in
            if foldersFirst, a.isNavigableFolder != b.isNavigableFolder { return a.isNavigableFolder }
            for d in descriptors {
                // Missing values sort last in both directions (rule 9, DESIGN.md §3.3).
                let aMissing = isMissing(a, d.key), bMissing = isMissing(b, d.key)
                if aMissing != bMissing { return bMissing }
                if aMissing { continue }
                switch compare(a, b, by: d.key) {
                case .orderedSame: continue
                case .orderedAscending: return d.ascending
                case .orderedDescending: return !d.ascending
                }
            }
            if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
            if a.id.device != b.id.device { return a.id.device < b.id.device }
            return a.id.inode < b.id.inode
        }
    }

    static func isMissing(_ item: FileItem, _ key: SortKey) -> Bool {
        switch key {
        case .size: item.isNavigableFolder || item.size == nil
        case .dateModified: item.modified == nil
        case .dateCreated: item.created == nil
        case .dateAdded: item.added == nil
        case .dateLastOpened: item.lastOpened == nil
        default: false
        }
    }

    /// Ascending comparison of two items that both have a value for `key`.
    static func compare(_ a: FileItem, _ b: FileItem, by key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            if a.sortKey == b.sortKey { return .orderedSame }
            return a.sortKey < b.sortKey ? .orderedAscending : .orderedDescending
        case .kind:
            return KindNames.name(for: a).localizedStandardCompare(KindNames.name(for: b))
        case .fileExtension:
            return a.pathExtension.compare(b.pathExtension)
        case .folder:
            return a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
        case .size:
            return compareOptional(a.size, b.size)
        case .dateModified:
            return compareOptional(a.modified, b.modified)
        case .dateCreated:
            return compareOptional(a.created, b.created)
        case .dateAdded:
            return compareOptional(a.added, b.added)
        case .dateLastOpened:
            return compareOptional(a.lastOpened, b.lastOpened)
        case .tags, .manual:
            // Lazy attributes (side tables) arrive in a later milestone.
            return .orderedSame
        }
    }

    private static func compareOptional<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, _), (_, nil): .orderedSame   // handled by isMissing
        case let (x?, y?): x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
    }
}
