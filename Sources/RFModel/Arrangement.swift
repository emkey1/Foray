import Foundation

public enum SortKey: String, Codable, Sendable, CaseIterable {
    case name, kind, size, dateModified, dateCreated, dateAdded, dateLastOpened, tags
    case fileExtension = "extension"
    /// Free icon positions (icon view). Other modes use the positions' reading order.
    case manual

    /// Direction a header click starts with, matching Finder: newest and largest first.
    public var defaultAscending: Bool {
        switch self {
        case .size, .dateModified, .dateCreated, .dateAdded, .dateLastOpened: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .size: "Size"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .dateAdded: "Date Added"
        case .dateLastOpened: "Date Last Opened"
        case .tags: "Tags"
        case .fileExtension: "Extension"
        case .manual: "None"
        }
    }
}

public struct SortDescriptor: Codable, Hashable, Sendable {
    public var key: SortKey
    public var ascending: Bool

    public init(_ key: SortKey, ascending: Bool? = nil) {
        self.key = key
        self.ascending = ascending ?? key.defaultAscending
    }
}

public enum GroupKey: String, Codable, Sendable, CaseIterable {
    case kind, dateModified, dateCreated, dateAdded, size

    public var title: String {
        switch self {
        case .kind: "Kind"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .dateAdded: "Date Added"
        case .size: "Size"
        }
    }
}

/// Which items are shown and in what order. Independent of view mode (DESIGN.md §3.3).
public struct Arrangement: Codable, Hashable, Sendable {
    /// Primary first. Name, then FileID, are implicit final tiebreakers.
    public var sort: [SortDescriptor]
    public var groupBy: GroupKey?
    public var foldersFirst: Bool
    public var showHidden: Bool
    public var kindFilter: Set<KindCategory.ID>

    public static let maxSortKeys = 3

    public init(
        sort: [SortDescriptor] = [SortDescriptor(.name)], groupBy: GroupKey? = nil, foldersFirst: Bool = false,
        showHidden: Bool = false, kindFilter: Set<KindCategory.ID> = []
    ) {
        self.sort = sort
        self.groupBy = groupBy
        self.foldersFirst = foldersFirst
        self.showHidden = showHidden
        self.kindFilter = kindFilter
    }

    public var primary: SortDescriptor { sort.first ?? SortDescriptor(.name) }

    /// List header click / Sort menu: makes `key` primary. Re-selecting the current primary
    /// reverses it. Secondary keys are kept unless they duplicate the new primary.
    public mutating func setPrimary(_ key: SortKey) {
        if primary.key == key {
            sort[0].ascending.toggle()
            return
        }
        sort.removeAll { $0.key == key }
        sort.insert(SortDescriptor(key), at: 0)
        if sort.count > Self.maxSortKeys { sort.removeLast(sort.count - Self.maxSortKeys) }
    }

    /// Shift-click on a list header: adds `key` as the last secondary key, reverses it if it's
    /// already secondary. Never changes the primary key.
    public mutating func toggleSecondary(_ key: SortKey) {
        guard primary.key != key else { return }
        if let i = sort.firstIndex(where: { $0.key == key }) {
            sort[i].ascending.toggle()
        } else {
            sort.append(SortDescriptor(key))
            if sort.count > Self.maxSortKeys { sort.remove(at: 1) }
        }
    }
}
