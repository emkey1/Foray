import Foundation

/// What a tab shows (DESIGN.md §5.3). Recents, tags, Trash and the rest arrive with their
/// milestones.
public enum Location: Hashable, Codable, Sendable {
    case folder(URL)
    case computer
    case search(SearchQuery)
    /// Every Trash folder (home and each volume's) together.
    case trash
    /// Files opened in the last 30 days (Spotlight).
    case recents

    public var searchQuery: SearchQuery? {
        if case .search(let q) = self { return q }
        return nil
    }

    public var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    /// Title without I/O. RFFileSystem provides localized display names (DESIGN.md §5.2: no I/O here).
    public var fallbackTitle: String {
        switch self {
        case .folder(let url): url.path == "/" ? "/" : url.lastPathComponent
        case .computer: "Computer"
        case .search(let q): q.rawSpotlight == nil ? "Searching “\(q.text)”" : q.text
        case .trash: "Trash"
        case .recents: "Recents"
        }
    }

    public var settingsClass: LocationClass {
        switch self {
        case .folder(let url):
            let path = url.standardizedFileURL.path
            if path == "/" || (path.hasPrefix("/Volumes/") && url.pathComponents.count == 3) { return .volumeRoot }
            return .folder
        case .computer:
            return .computer
        case .search:
            return .searchResults
        case .trash:
            return .trash
        case .recents:
            return .recents
        }
    }
}

/// Settings classes: each has its own default view settings (DESIGN.md §3.3).
public enum LocationClass: String, Codable, Sendable, CaseIterable {
    case folder, volumeRoot, computer, searchResults, recents, trash, network, tag
    /// The desktop Foray draws when it stands in for Finder.
    case desktop
}

/// One back/forward entry: where the tab was, and what was selected there.
public struct HistoryEntry: Hashable, Codable, Sendable {
    public var location: Location
    public var selectedNames: [String]

    public init(location: Location, selectedNames: [String] = []) {
        self.location = location
        self.selectedNames = selectedNames
    }
}

/// Per-tab navigation history.
public struct NavigationHistory: Codable, Sendable {
    public private(set) var back: [HistoryEntry] = []
    public private(set) var current: HistoryEntry
    public private(set) var forward: [HistoryEntry] = []
    public static let limit = 100

    public init(_ start: Location) { current = HistoryEntry(location: start) }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Navigating somewhere new clears forward history. Re-visiting the current location is a no-op.
    public mutating func visit(_ location: Location, leaving departing: HistoryEntry? = nil) {
        guard location != current.location else { return }
        back.append(departing ?? current)
        if back.count > Self.limit { back.removeFirst() }
        forward.removeAll()
        current = HistoryEntry(location: location)
    }

    /// Refining a search replaces the current entry instead of adding one per keystroke.
    public mutating func replaceCurrent(_ location: Location) {
        current = HistoryEntry(location: location, selectedNames: current.selectedNames)
    }

    @discardableResult
    public mutating func goBack(leaving departing: HistoryEntry? = nil) -> HistoryEntry? {
        guard let previous = back.popLast() else { return nil }
        forward.append(departing ?? current)
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward(leaving departing: HistoryEntry? = nil) -> HistoryEntry? {
        guard let next = forward.popLast() else { return nil }
        back.append(departing ?? current)
        current = next
        return next
    }
}
