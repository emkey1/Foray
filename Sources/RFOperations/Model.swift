import Foundation

/// What to do (DESIGN.md §5.7). Destinations are folders; names are chosen by the engine.
public enum OperationRequest: Sendable, Equatable {
    case copy([URL], to: URL)
    case move([URL], to: URL)
    case duplicate([URL])
    case trash([URL])
    /// Permanent; not undoable. The UI confirms first.
    case delete([URL])
    case rename(URL, to: String)
    /// New folder in `in`, optionally moving `moving` into it (New Folder with Selection).
    case newFolder(in: URL, name: String? = nil, moving: [URL] = [])
    /// Moves each item back to an exact path (undo/redo, Put Back). Fails per item if taken.
    case restore([Pair])
    /// Adds and removes tags (by name) on each item, keeping its other tags.
    case changeTags([URL], add: [String], remove: [String])
    /// Sets each item's tags exactly (undo/redo of tag changes).
    case setTags([TagAssignment])

    public struct TagAssignment: Sendable, Equatable, Hashable {
        public var url: URL
        public var tags: [String]
        public init(url: URL, tags: [String]) {
            self.url = url
            self.tags = tags
        }
    }

    public struct Pair: Sendable, Equatable, Hashable {
        public var from: URL
        public var to: URL
        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public var title: String {
        func n(_ items: [URL]) -> String { items.count == 1 ? "“\(items[0].lastPathComponent)”" : "\(items.count) items" }
        switch self {
        case .copy(let items, let dir): return "Copying \(n(items)) to “\(dir.lastPathComponent)”"
        case .move(let items, let dir): return "Moving \(n(items)) to “\(dir.lastPathComponent)”"
        case .duplicate(let items): return "Duplicating \(n(items))"
        case .trash(let items): return "Moving \(n(items)) to the Trash"
        case .delete(let items): return "Deleting \(n(items))"
        case .rename(let item, let name): return "Renaming “\(item.lastPathComponent)” to “\(name)”"
        case .newFolder: return "Creating a folder"
        case .restore(let pairs): return pairs.count == 1 ? "Restoring “\(pairs[0].to.lastPathComponent)”" : "Restoring \(pairs.count) items"
        case .changeTags(let items, _, _): return "Tagging \(n(items))"
        case .setTags(let list): return list.count == 1 ? "Tagging “\(list[0].url.lastPathComponent)”" : "Tagging \(list.count) items"
        }
    }

    /// The name used in Undo/Redo menu titles ("Undo Move").
    public var undoName: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        case .duplicate: "Duplicate"
        case .trash: "Move to Trash"
        case .delete: "Delete"
        case .rename: "Rename"
        case .newFolder: "New Folder"
        case .restore: "Restore"
        case .changeTags, .setTags: "Tags"
        }
    }
}

/// Moves an item to the Trash and returns where it went. Injectable so tests use a private folder.
public typealias TrashFunction = @Sendable (URL) throws -> URL

public enum Trash {
    /// The system Trash (records Put Back information like Finder; M0 S4).
    public static let system: TrashFunction = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }
}

public enum ConflictResolution: Sendable, Equatable {
    /// The existing item goes to the Trash (recoverable; Finder deletes it), then the new one takes its place.
    case replace
    case keepBoth
    case skip
    case stop
}

public struct ConflictQuestion: Sendable {
    public let incoming: URL
    public let existing: URL
    public let incomingIsFolder: Bool
    public let existingIsFolder: Bool
    public let incomingModified: Date?
    public let existingModified: Date?
    /// More conflicts may follow in this job ("Apply to all" makes sense).
    public let moreToCome: Bool
}

public struct ConflictAnswer: Sendable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool

    public init(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

/// One item that couldn't be processed. The job carries on with the rest.
public struct ItemError: Sendable, Error, CustomStringConvertible {
    public let url: URL
    public let code: Int32
    public let action: String

    public var description: String { message }

    public var message: String {
        let name = url.lastPathComponent
        let reason: String = switch code {
        case EACCES, EPERM: "you don't have permission, or the item is locked"
        case ENOENT: "it no longer exists"
        case ENOSPC: "there isn't enough free space"
        case EEXIST: "an item with that name already exists"
        case EROFS: "the disk is read-only"
        case ENAMETOOLONG: "the name is too long"
        case EXDEV: "it's on a different disk"
        case EINVAL: "it can't be put inside itself"
        case EFBIG: "the file is too large for the destination disk"
        case EIO: "the disk reported an input/output error"
        case ECANCELED: "the operation was cancelled"
        default: String(cString: strerror(code))
        }
        return "Couldn't \(action) “\(name)”: \(reason) (\(code))."
    }
}

/// What a job did, as an ordered log of facts. Undo is computed from it (`revert`).
public struct OperationResult: Sendable {
    public enum Step: Sendable, Equatable {
        /// A new item (copy, duplicate, new folder).
        case created(URL)
        /// An item moved (move, rename, restore).
        case moved(OperationRequest.Pair)
        /// An item went to the Trash: original location → location in the Trash. Includes items
        /// replaced by a conflict resolution.
        case trashed(OperationRequest.Pair)
        /// An item's tags changed from `before` to `after`.
        case tagged(URL, before: [String], after: [String])
    }

    /// In the order things happened.
    public var log: [Step] = []
    public var deleted: [URL] = []
    public var errors: [ItemError] = []
    public var stopped = false
    /// Folders whose contents changed, so views can refresh without waiting for FSEvents.
    public var changedFolders: Set<URL> = []

    public init() {}

    public mutating func record(_ step: Step) { log.append(step) }

    public var created: [URL] { log.compactMap { if case .created(let u) = $0 { u } else { nil } } }
    public var moved: [OperationRequest.Pair] { log.compactMap { if case .moved(let p) = $0 { p } else { nil } } }
    public var trashed: [OperationRequest.Pair] { log.compactMap { if case .trashed(let p) = $0 { p } else { nil } } }

    /// Items the user would expect selected afterwards (in their new places).
    public var resultingItems: [URL] { created + moved.map(\.to) }

    /// Requests that undo this result: every step reversed, in reverse order (so e.g. a folder is
    /// taken back out of the Trash before items are moved back into it). Consecutive steps of the
    /// same kind become one request. Nil if there's nothing to undo.
    public func revert() -> [OperationRequest]? {
        var steps: [OperationRequest] = []
        for step in log.reversed() {
            switch step {
            case .created(let url):
                if case .trash(let urls) = steps.last { steps[steps.count - 1] = .trash(urls + [url]) } else { steps.append(.trash([url])) }
            case .moved(let p), .trashed(let p):
                let back = OperationRequest.Pair(from: p.to, to: p.from)
                if case .restore(let pairs) = steps.last { steps[steps.count - 1] = .restore(pairs + [back]) } else { steps.append(.restore([back])) }
            case .tagged(let url, let before, _):
                let back = OperationRequest.TagAssignment(url: url, tags: before)
                if case .setTags(let list) = steps.last { steps[steps.count - 1] = .setTags(list + [back]) } else { steps.append(.setTags([back])) }
            }
        }
        return steps.isEmpty ? nil : steps
    }
}
