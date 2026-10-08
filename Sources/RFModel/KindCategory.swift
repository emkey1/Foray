import Foundation
import Synchronization
import UniformTypeIdentifiers

/// A named, user-editable file-type category (DESIGN.md §3.2). Built-in rules were validated
/// against real system types in M0 (Spikes/RESULTS.md, "Kind categories").
public struct KindCategory: Codable, Hashable, Identifiable, Sendable {
    public typealias ID = String

    public let id: ID
    public var name: String
    public var symbol: String
    /// Any-of, hierarchy-aware conformance (UTType identifiers).
    public var conformsTo: [String]
    /// Any-of, lowercase, without dots. Needed for extensions the system maps to dynamic types.
    public var extensions: [String]
    public var matchesExecutables: Bool
    /// Carve-outs, applied last.
    public var excluding: [String]

    public init(
        id: ID, name: String, symbol: String, conformsTo: [String], extensions: [String] = [],
        matchesExecutables: Bool = false, excluding: [String] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.conformsTo = conformsTo
        self.extensions = extensions
        self.matchesExecutables = matchesExecutables
        self.excluding = excluding
    }
}

extension KindCategory {
    public static let builtIns: [KindCategory] = [
        KindCategory(id: "folders", name: "Folders", symbol: "folder", conformsTo: ["public.folder"],
                     excluding: ["com.apple.package"]),
        KindCategory(id: "documents", name: "Documents", symbol: "doc.text",
                     conformsTo: ["com.adobe.pdf", "public.rtf", "com.apple.rtfd", "public.plain-text",
                                  "net.daringfireball.markdown", "public.spreadsheet", "public.presentation",
                                  "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                                  "com.apple.iwork.pages.sffpages", "org.idpf.epub-container", "public.html"],
                     extensions: ["pages", "numbers", "key", "odt", "ods", "odp"],
                     excluding: codeTypes),
        KindCategory(id: "images", name: "Images", symbol: "photo", conformsTo: ["public.image"]),
        KindCategory(id: "video", name: "Video", symbol: "film", conformsTo: ["public.movie"],
                     extensions: ["mkv", "webm", "flv"]),
        KindCategory(id: "audio", name: "Audio", symbol: "music.note", conformsTo: ["public.audio"]),
        // Not public.script/public.executable: .js conforms to both. Scripts count when executable.
        KindCategory(id: "programs", name: "Programs", symbol: "app",
                     conformsTo: ["com.apple.application", "public.unix-executable"], matchesExecutables: true),
        KindCategory(id: "archives", name: "Archives", symbol: "archivebox",
                     conformsTo: ["public.archive", "public.disk-image"], extensions: ["7z", "rar", "xz", "zst"]),
        KindCategory(id: "code", name: "Code", symbol: "chevron.left.forwardslash.chevron.right",
                     conformsTo: codeTypes,
                     extensions: ["rs", "go", "kt", "ts", "tsx", "jsx", "toml", "ini", "cfg", "gradle", "cmake",
                                  "dockerfile", "lua", "zig"],
                     excluding: ["public.image"]),  // SVG conforms to public.xml
        KindCategory(id: "pdfs", name: "PDFs", symbol: "doc.richtext", conformsTo: ["com.adobe.pdf"]),
        KindCategory(id: "fonts", name: "Fonts", symbol: "textformat", conformsTo: ["public.font"],
                     extensions: ["woff", "woff2"]),
    ]

    static let codeTypes = ["public.source-code", "public.script", "public.json", "public.yaml", "public.xml",
                            "com.apple.property-list"]
}

/// Matches items against a set of categories. Matching by type and extension is memoized, so the
/// per-item cost is one dictionary lookup (plus the executable-bit check).
public final class KindCatalog: Sendable {
    public let categories: [KindCategory]
    private let memo = Mutex<[String: Set<KindCategory.ID>]>([:])
    private let resolved: [Resolved]

    private struct Resolved: Sendable {
        let id: KindCategory.ID
        let conformsTo: [UTType]
        let extensions: Set<String>
        let excluding: [UTType]
        let matchesExecutables: Bool
    }

    public init(categories: [KindCategory] = KindCategory.builtIns) {
        self.categories = categories
        self.resolved = categories.map { c in
            Resolved(id: c.id, conformsTo: c.conformsTo.compactMap { UTType($0) },
                     extensions: Set(c.extensions.map { $0.lowercased() }),
                     excluding: c.excluding.compactMap { UTType($0) }, matchesExecutables: c.matchesExecutables)
        }
    }

    public static let shared = KindCatalog()

    public func category(_ id: KindCategory.ID) -> KindCategory? { categories.first { $0.id == id } }

    /// IDs of every category the item belongs to.
    public func categories(of item: FileItem) -> Set<KindCategory.ID> {
        var result = staticMatches(type: item.contentType, ext: item.pathExtension)
        let isRegularExecutable = item.flags.contains(.executable) && !item.flags.contains(.directory)
        if isRegularExecutable {
            for r in resolved where r.matchesExecutables && !r.excluding.contains(where: item.contentType.conforms) {
                result.insert(r.id)
            }
        }
        return result
    }

    public func matches(_ item: FileItem, anyOf ids: Set<KindCategory.ID>) -> Bool {
        ids.isEmpty || !categories(of: item).isDisjoint(with: ids)
    }

    public func staticMatches(type: UTType, ext: String) -> Set<KindCategory.ID> {
        let memoKey = type.identifier + "|" + ext
        if let hit = memo.withLock({ $0[memoKey] }) { return hit }
        var ids = Set<KindCategory.ID>()
        for r in resolved {
            if r.excluding.contains(where: type.conforms) { continue }
            if r.conformsTo.contains(where: type.conforms) || r.extensions.contains(ext) { ids.insert(r.id) }
        }
        memo.withLock { $0[memoKey] = ids }
        return ids
    }
}
