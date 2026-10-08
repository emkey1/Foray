import Foundation
import UniformTypeIdentifiers

/// Stable identity of a filesystem object while its volume is mounted (DESIGN.md §5.3).
public struct FileID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let device: Int32
    public let inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public var description: String { "\(device):\(inode)" }
}

public struct ItemFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let directory = ItemFlags(rawValue: 1 << 0)
    public static let package = ItemFlags(rawValue: 1 << 1)
    public static let symlink = ItemFlags(rawValue: 1 << 2)
    public static let alias = ItemFlags(rawValue: 1 << 3)
    public static let hidden = ItemFlags(rawValue: 1 << 4)
    public static let locked = ItemFlags(rawValue: 1 << 5)
    public static let executable = ItemFlags(rawValue: 1 << 6)
    public static let hasCustomIcon = ItemFlags(rawValue: 1 << 7)
    public static let mountPoint = ItemFlags(rawValue: 1 << 8)
    public static let dataless = ItemFlags(rawValue: 1 << 9)
}

/// Immutable value snapshot of one item. Built off-main; cheap to copy.
/// Expensive attributes (tags, last-opened date, folder sizes) live in side tables keyed by `FileID`.
public struct FileItem: Identifiable, Hashable, Sendable {
    public let id: FileID
    public let url: URL
    public let name: String
    public let displayName: String
    public let contentType: UTType
    public let flags: ItemFlags
    /// Logical bytes; nil for folders.
    public let size: Int64?
    public let allocatedSize: Int64?
    public let created: Date?
    public let modified: Date?
    /// Status change time: moves when metadata such as tags changes (used to invalidate caches).
    public let changed: Date?
    public let added: Date?
    public let sortKey: NaturalSortKey

    public init(
        id: FileID, url: URL, name: String, displayName: String? = nil, contentType: UTType, flags: ItemFlags,
        size: Int64?, allocatedSize: Int64? = nil, created: Date? = nil, modified: Date? = nil, changed: Date? = nil,
        added: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.displayName = displayName ?? name
        self.contentType = contentType
        self.flags = flags
        self.size = size
        self.allocatedSize = allocatedSize
        self.created = created
        self.modified = modified
        self.changed = changed
        self.added = added
        self.sortKey = NaturalSortKey(self.displayName)
    }

    /// A folder the user navigates into (packages open like files).
    public var isNavigableFolder: Bool { flags.contains(.directory) && !flags.contains(.package) }

    public var pathExtension: String { (name as NSString).pathExtension.lowercased() }
}
