import AppKit
import RFFileSystem
import RFModel

/// App-wide state: view settings and the saved session. Broadcasts settings changes so every
/// tab showing a location with the same settings source updates live (DESIGN.md §3.3).
@MainActor
public final class AppModel {
    /// Replaceable so tests never touch the user's real settings.
    public static var shared = AppModel(store: .shared)

    private let store: AppSupportStore
    private static let settingsFile = "view-settings.json"
    private static let sessionFile = "session.json"

    public private(set) var settings: ViewSettingsDatabase
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var saveScheduled = false

    public init(store: AppSupportStore) {
        self.store = store
        settings = store.load(ViewSettingsDatabase.self, from: Self.settingsFile) ?? ViewSettingsDatabase()
    }

    // MARK: View settings

    func resolve(_ cls: LocationClass, folder: FolderKey?) -> (ViewSettings, SettingsSource) {
        settings.resolve(cls, folder: folder)
    }

    func record(_ s: ViewSettings, cls: LocationClass, folder: FolderKey?) {
        settings.update(s, cls: cls, folder: folder)
        settingsChanged()
    }

    /// Settings › Views: same settings everywhere, or remembered per folder.
    func setSettingsModel(_ m: SettingsModel) {
        settings.model = m
        settingsChanged()
    }

    /// View Options › Use as Defaults.
    func setClassDefault(_ s: ViewSettings, cls: LocationClass) {
        settings.classDefaults[cls] = s
        settingsChanged()
    }

    func pin(_ s: ViewSettings, folder: FolderKey) {
        settings.pin(s, folder: folder)
        settingsChanged()
    }

    func unpin(_ folder: FolderKey) {
        settings.unpin(folder)
        settingsChanged()
    }

    func isPinned(_ folder: FolderKey?) -> Bool { settings.override(for: folder) != nil }

    func observeSettings(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func settingsChanged() {
        for handler in observers.values { handler() }
        guard !saveScheduled else { return }
        saveScheduled = true
        // Coalesce bursts (e.g. column resizing) into one write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                self.saveScheduled = false
                self.store.save(self.settings, to: Self.settingsFile)
            }
        }
    }

    public func flush() { store.save(settings, to: Self.settingsFile) }

    // MARK: Sidebar favorites

    /// Saved as bookmarks so favorites survive renames and moves.
    private struct SavedFavorite: Codable {
        var path: String
        var bookmark: Data?
    }

    private static let sidebarFile = "sidebar.json"
    private var favoriteObservers: [UUID: @MainActor () -> Void] = [:]

    public private(set) lazy var favorites: [URL] = loadFavorites()

    private func loadFavorites() -> [URL] {
        guard let saved = store.load([SavedFavorite].self, from: Self.sidebarFile) else { return Self.defaultFavorites }
        return saved.map { fav in
            var stale = false
            if let data = fav.bookmark,
               let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                return url
            }
            return URL(fileURLWithPath: fav.path)
        }
    }

    static var defaultFavorites: [URL] {
        [StandardLocation.applications, .desktop, .documents, .downloads, .home].compactMap(\.url)
    }

    /// Adds folders (skipping ones already there) at `index`, or at the end.
    func addFavorites(_ urls: [URL], at index: Int? = nil) {
        let new = urls.map(\.standardizedFileURL).filter { url in !favorites.contains { $0.standardizedFileURL == url } }
        guard !new.isEmpty else { return }
        favorites.insert(contentsOf: new, at: min(index ?? favorites.count, favorites.count))
        favoritesChanged()
    }

    func removeFavorite(at index: Int) {
        guard favorites.indices.contains(index) else { return }
        favorites.remove(at: index)
        favoritesChanged()
    }

    func moveFavorite(from: Int, to: Int) {
        guard favorites.indices.contains(from) else { return }
        let url = favorites.remove(at: from)
        favorites.insert(url, at: min(to > from ? to - 1 : to, favorites.count))
        favoritesChanged()
    }

    func observeFavorites(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        favoriteObservers[id] = handler
        return id
    }

    private func favoritesChanged() {
        let saved = favorites.map { SavedFavorite(path: $0.path, bookmark: try? $0.bookmarkData()) }
        store.save(saved, to: Self.sidebarFile)
        for handler in favoriteObservers.values { handler() }
    }

    // MARK: Icon positions (icon view, Sort By None)

    private static let iconPositionsFile = "icon-positions.json"
    private var iconPositionsSaveScheduled = false
    /// Folder path → item name → top-left of its cell, in points.
    private lazy var iconPositions: [String: [String: [Double]]] =
        store.load([String: [String: [Double]]].self, from: Self.iconPositionsFile) ?? [:]

    func iconPositions(in folder: URL) -> [String: CGPoint] {
        (iconPositions[folder.standardizedFileURL.path] ?? [:]).compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    func setIconPositions(_ positions: [String: CGPoint], in folder: URL, replacing: Bool = false) {
        let key = folder.standardizedFileURL.path
        var current = replacing ? [:] : (iconPositions[key] ?? [:])
        for (name, p) in positions { current[name] = [Double(p.x), Double(p.y)] }
        iconPositions[key] = current
        guard !iconPositionsSaveScheduled else { return }
        iconPositionsSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.iconPositionsSaveScheduled = false
            self.store.save(self.iconPositions, to: Self.iconPositionsFile)
        }
    }

    // MARK: Recent folders (Go › Recent Folders, the Dock menu)

    public static let recentFolderLimit = 10
    private static let recentFoldersFile = "recent-folders.json"
    private var recentFoldersSaveScheduled = false

    public private(set) lazy var recentFolders: [URL] =
        (store.load([String].self, from: Self.recentFoldersFile) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }

    func recordVisit(_ folder: URL) {
        let url = folder.standardizedFileURL
        guard url.path != recentFolders.first?.standardizedFileURL.path else { return }
        recentFolders.removeAll { $0.standardizedFileURL.path == url.path }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > Self.recentFolderLimit { recentFolders.removeLast(recentFolders.count - Self.recentFolderLimit) }
        // Navigation is frequent; write at most once a second.
        guard !recentFoldersSaveScheduled else { return }
        recentFoldersSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.recentFoldersSaveScheduled = false
            self.store.save(self.recentFolders.map(\.path), to: Self.recentFoldersFile)
        }
    }

    func clearRecentFolders() {
        recentFolders = []
        store.save([String](), to: Self.recentFoldersFile)
    }

    // MARK: Recent searches

    public static let recentSearchLimit = 12
    private static let recentSearchesFile = "recent-searches.json"
    private var recentSearchObservers: [UUID: @MainActor () -> Void] = [:]

    /// Most recent first. A search is recorded when the user leaves it, not on every keystroke.
    public private(set) lazy var recentSearches: [SearchQuery] =
        store.load([SearchQuery].self, from: Self.recentSearchesFile) ?? []

    func recordSearch(_ q: SearchQuery) {
        guard !q.isEmpty else { return }
        recentSearches.removeAll { $0.text == q.text && $0.scope == q.scope && $0.match == q.match }
        recentSearches.insert(q, at: 0)
        if recentSearches.count > Self.recentSearchLimit { recentSearches.removeLast(recentSearches.count - Self.recentSearchLimit) }
        recentSearchesChanged()
    }

    func clearRecentSearches() {
        recentSearches = []
        recentSearchesChanged()
    }

    func observeRecentSearches(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        recentSearchObservers[id] = handler
        return id
    }

    private func recentSearchesChanged() {
        store.save(recentSearches, to: Self.recentSearchesFile)
        for handler in recentSearchObservers.values { handler() }
    }

    // MARK: Session

    public struct Session: Codable {
        public struct Window: Codable {
            public var tabs: [Location]
            public var selectedTab: Int
            public var frame: String?
        }
        public var windows: [Window]
    }

    public func saveSession(_ session: Session) { store.save(session, to: Self.sessionFile) }
    public func loadSession() -> Session? { store.load(Session.self, from: Self.sessionFile) }
}
