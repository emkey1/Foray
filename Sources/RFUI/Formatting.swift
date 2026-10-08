import Foundation
import RFModel

@MainActor
enum Formatting {
    private static let relative: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func date(_ date: Date?, relative useRelative: Bool) -> String {
        guard let date else { return "--" }
        return (useRelative ? relative : absolute).string(from: date)
    }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "--" }
        return self.bytes.string(fromByteCount: bytes)
    }

    static func size(for item: FileItem) -> String {
        item.isNavigableFolder ? "--" : size(item.size)
    }

    static func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n.formatted()) items" }

    /// Search results' "Where": the enclosing folder relative to the search scope ("Projects/app/src"),
    /// or the full path (with ~) when searching This Mac.
    static func whereText(_ item: FileItem, base: URL?) -> String {
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        if let base {
            let root = base.standardizedFileURL.path
            if parent == root { return base.lastPathComponent }
            if parent.hasPrefix(root + "/") { return base.lastPathComponent + parent.dropFirst(root.count) }
        }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    static func text(for item: FileItem, column: ListColumn, relativeDates: Bool, whereBase: URL? = nil) -> String {
        switch column {
        case .name: item.displayName
        case .dateModified: date(item.modified, relative: relativeDates)
        case .dateCreated: date(item.created, relative: relativeDates)
        case .dateAdded: date(item.added, relative: relativeDates)
        case .size: size(for: item)
        case .kind: KindNames.name(for: item)
        case .fileExtension: item.pathExtension.isEmpty ? "--" : item.pathExtension
        case .folder: whereText(item, base: whereBase)
        }
    }
}
