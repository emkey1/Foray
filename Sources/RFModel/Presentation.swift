import Foundation

public enum ViewMode: String, Codable, Sendable, CaseIterable {
    case icon, list, column, gallery

    public var title: String {
        switch self {
        case .icon: "Icons"
        case .list: "List"
        case .column: "Columns"
        case .gallery: "Gallery"
        }
    }
}

public enum ListColumn: String, Codable, Sendable, CaseIterable {
    case name, dateModified, dateCreated, dateAdded, size, kind, fileExtension
    /// Recents only (other locations don't know it).
    case dateLastOpened
    /// Enclosing folder, relative to the search scope (search results).
    case folder

    public var sortKey: SortKey {
        switch self {
        case .name: .name
        case .dateModified: .dateModified
        case .dateCreated: .dateCreated
        case .dateAdded: .dateAdded
        case .dateLastOpened: .dateLastOpened
        case .size: .size
        case .kind: .kind
        case .fileExtension: .fileExtension
        case .folder: .folder
        }
    }

    public var title: String { sortKey.title }

    public var defaultWidth: Double {
        switch self {
        case .name: 280
        case .kind: 140
        case .size: 80
        case .fileExtension: 70
        case .folder: 220
        default: 160
        }
    }
}

public struct ListColumnSpec: Codable, Hashable, Sendable {
    public var column: ListColumn
    public var width: Double

    public init(_ column: ListColumn, width: Double? = nil) {
        self.column = column
        self.width = width ?? column.defaultWidth
    }
}

public struct IconOptions: Codable, Hashable, Sendable {
    public enum LabelPosition: String, Codable, Sendable { case bottom, right }
    public var iconSize: Double = 64
    public var gridSpacing: Double = 24
    public var labelPosition: LabelPosition = .bottom
    public var showPreviews = true
    /// Sort By None: moved icons land on the nearest free grid spot (Finder's "Snap to Grid").
    public var snapToGrid = false
    public init() {}

    // Settings saved before a field existed still load: missing fields take their defaults.
    private enum CodingKeys: String, CodingKey { case iconSize, gridSpacing, labelPosition, showPreviews, snapToGrid }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IconOptions()
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? d.iconSize
        gridSpacing = try c.decodeIfPresent(Double.self, forKey: .gridSpacing) ?? d.gridSpacing
        labelPosition = try c.decodeIfPresent(LabelPosition.self, forKey: .labelPosition) ?? d.labelPosition
        showPreviews = try c.decodeIfPresent(Bool.self, forKey: .showPreviews) ?? d.showPreviews
        snapToGrid = try c.decodeIfPresent(Bool.self, forKey: .snapToGrid) ?? d.snapToGrid
    }
}

public struct ListOptions: Codable, Hashable, Sendable {
    public var columns: [ListColumnSpec] = [
        ListColumnSpec(.name), ListColumnSpec(.dateModified), ListColumnSpec(.size), ListColumnSpec(.kind),
    ]
    public var iconSize: Double = 16
    public var relativeDates = true
    /// Show the sort key's column automatically when it isn't visible (rule 5, DESIGN.md §3.3).
    public var autoShowSortColumn = false
    /// Total up folder sizes in the background (Finder's "Calculate all sizes").
    public var calculateAllSizes = false
    public init() {}

    // Settings saved before a field existed still load: missing fields take their defaults.
    private enum CodingKeys: String, CodingKey { case columns, iconSize, relativeDates, autoShowSortColumn, calculateAllSizes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ListOptions()
        columns = try c.decodeIfPresent([ListColumnSpec].self, forKey: .columns) ?? d.columns
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? d.iconSize
        relativeDates = try c.decodeIfPresent(Bool.self, forKey: .relativeDates) ?? d.relativeDates
        autoShowSortColumn = try c.decodeIfPresent(Bool.self, forKey: .autoShowSortColumn) ?? d.autoShowSortColumn
        calculateAllSizes = try c.decodeIfPresent(Bool.self, forKey: .calculateAllSizes) ?? d.calculateAllSizes
    }

    public func isVisible(_ key: SortKey) -> Bool { columns.contains { $0.column.sortKey == key } }
}

public struct ColumnOptions: Codable, Hashable, Sendable {
    public var columnWidth: Double = 240
    public var showPreviewColumn = true
    public init() {}
}

public struct GalleryOptions: Codable, Hashable, Sendable {
    public var thumbnailSize: Double = 64
    public var showMetadata = true
    public init() {}
}

/// How items are drawn. Options for every mode are kept, so switching back restores them.
public struct Presentation: Codable, Hashable, Sendable {
    public var mode: ViewMode = .icon
    public var icon = IconOptions()
    public var list = ListOptions()
    public var column = ColumnOptions()
    public var gallery = GalleryOptions()
    public var previewPaneVisible = false
    public init(mode: ViewMode = .icon) { self.mode = mode }
}

public struct ViewSettings: Codable, Hashable, Sendable {
    public var arrangement: Arrangement
    public var presentation: Presentation

    public init(arrangement: Arrangement = Arrangement(), presentation: Presentation = Presentation()) {
        self.arrangement = arrangement
        self.presentation = presentation
    }
}
