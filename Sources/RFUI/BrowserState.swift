import AppKit
import RFFileSystem
import RFModel
import RFSearch

/// Per-tab state (DESIGN.md §5.3): location, history, settings, the arranged snapshot and the
/// selection. Loading and arranging run off the main thread; results are applied here.
@MainActor
final class BrowserState {
    enum LoadState: Equatable {
        case loading
        case partial(Int)
        case complete
        case failed(String, permission: Bool)
    }

    enum Change {
        case location, snapshot, settings, loadState, details, selection
        /// An expanded folder's contents (list view disclosure) were loaded or changed.
        case children(FileID)
    }

    private(set) var location: Location
    private(set) var history: NavigationHistory
    private(set) var settings: ViewSettings
    private(set) var settingsSource: SettingsSource = .classDefault(.folder)
    private(set) var details: LocationDetails
    /// Free space on the location's volume (fetched separately; it's slow).
    private(set) var availableCapacity: Int64?
    private(set) var snapshot: ItemSnapshot = .empty
    private(set) var loadState: LoadState = .loading
    /// Progress of the running search, when the location is a search.
    private(set) var searchStatus: SearchStatus?
    private(set) var selection: Set<FileID> = []
    /// The item the keyboard is on; kept across mode switches and reloads.
    var focusAnchor: FileID?

    /// Why each arrangement was requested (for tests and debugging).
    private(set) var rearrangeLog: [String] = []
    private var rawItems: [FileItem] = []
    private var loadTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var requestedGeneration = 0
    private var appliedGeneration = -1
    private var lastPartialArrange = Date.distantPast
    /// Names to select once the listing arrives (going back restores the previous selection).
    private var pendingSelection: [String] = []
    private var observers: [(Change) -> Void] = []
    private var settingsObserver: UUID?

    init(location: Location) {
        self.location = location
        self.history = NavigationHistory(location)
        self.details = .fallback(location)
        self.settings = AppModel.shared.resolve(location.settingsClass, folder: nil).0
        settingsObserver = AppModel.shared.observeSettings { [weak self] in self?.reresolveSettings() }
        load()
    }

    func invalidate() {
        loadTask?.cancel()
        detailsTask?.cancel()
        childTasks.values.forEach { $0.cancel() }
        if let settingsObserver { AppModel.shared.removeObserver(settingsObserver) }
    }

    func observe(_ handler: @escaping (Change) -> Void) { observers.append(handler) }
    private func notify(_ change: Change) { for o in observers { o(change) } }

    /// Selected items in display order, including items inside expanded folders.
    var selectedItems: [FileItem] {
        guard !selection.isEmpty else { return [] }
        var result = snapshot.items.filter { selection.contains($0.id) }
        if result.count < selection.count {
            for child in children.values { result += child.items.filter { selection.contains($0.id) } }
        }
        return result
    }

    /// Any item currently shown: top level or inside an expanded folder.
    func item(_ id: FileID) -> FileItem? {
        if let hit = snapshot.item(id) { return hit }
        for child in children.values { if let hit = child.item(id) { return hit } }
        return nil
    }

    // MARK: Expanded folders (list view disclosure triangles)

    /// Folders expanded in list view. Kept per tab, so they survive view-mode switches.
    private(set) var expanded: Set<FileID> = []
    /// Arranged contents of expanded folders (same sort and filters as the main list, no groups).
    private(set) var children: [FileID: ItemSnapshot] = [:]
    private var childRaw: [FileID: [FileItem]] = [:]
    private var childTasks: [FileID: Task<Void, Never>] = [:]
    private var recursiveBudget = 0

    /// Expands a folder in place. `recursive` (Option-click) also expands its subfolders as they
    /// load, up to a few hundred folders.
    func expand(_ folder: FileItem, recursive: Bool = false) {
        guard folder.isNavigableFolder else { return }
        if recursive { recursiveBudget = max(recursiveBudget, 300) }
        let alreadyExpanded = expanded.contains(folder.id)
        expanded.insert(folder.id)
        if recursive, let loaded = children[folder.id] {
            for sub in loaded.items where sub.isNavigableFolder && !expanded.contains(sub.id) && recursiveBudget > 0 {
                recursiveBudget -= 1
                expand(sub, recursive: true)
            }
        }
        guard !alreadyExpanded || childTasks[folder.id] == nil else { return }
        let id = folder.id
        let expandSubfolders = recursive
        childTasks[id] = Task { [weak self] in
            for await event in FolderContents.observe(folder.url) {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .partial: continue
                case .complete(let items): self.childRaw[id] = items
                case .failed: self.childRaw[id] = []
                }
                self.arrangeChildren(id)
                if expandSubfolders {
                    for sub in self.children[id]?.items ?? [] where sub.isNavigableFolder && self.recursiveBudget > 0 {
                        self.recursiveBudget -= 1
                        self.expand(sub, recursive: true)
                    }
                }
            }
        }
    }

    /// Collapses a folder and everything expanded inside it.
    func collapse(_ id: FileID) {
        guard expanded.remove(id) != nil else { return }
        childTasks.removeValue(forKey: id)?.cancel()
        let inside = children.removeValue(forKey: id)?.items.map(\.id) ?? []
        childRaw[id] = nil
        for child in inside where expanded.contains(child) { collapse(child) }
        selection.subtract(inside)
    }

    private func arrangeChildren(_ id: FileID) {
        guard let raw = childRaw[id] else { return }
        var arrangement = settings.arrangement
        arrangement.groupBy = nil
        children[id] = ArrangementEngine.arrange(raw, with: arrangement)
        notify(.children(id))
    }

    private func collapseAll() {
        childTasks.values.forEach { $0.cancel() }
        childTasks = [:]
        children = [:]
        childRaw = [:]
        expanded = []
    }

    // MARK: Navigation

    func navigate(to newLocation: Location, select names: [String] = []) {
        guard newLocation != location else { return }
        history.visit(newLocation, leaving: departingEntry())
        pendingSelection = names
        switchTo(newLocation)
    }

    func goBack() {
        guard let entry = history.goBack(leaving: departingEntry()) else { return }
        pendingSelection = entry.selectedNames
        switchTo(entry.location)
    }

    func goForward() {
        guard let entry = history.goForward(leaving: departingEntry()) else { return }
        pendingSelection = entry.selectedNames
        switchTo(entry.location)
    }

    /// Whether an active search follows folder changes made with the sidebar, path bar or Go menu
    /// (on by default; the scope bar's "Keep searching in new folders" checkbox).
    static var searchFollowsFolderChanges: Bool {
        get { UserDefaults.standard.object(forKey: "SearchFollowsFolderChanges") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SearchFollowsFolderChanges") }
    }

    /// Navigation by "going somewhere" (sidebar, path bar, Go menu, Go to Folder). During a search
    /// it re-runs the search in the new place instead of ending it. Opening a result uses `navigate`.
    func jump(to target: Location, select names: [String] = []) {
        if Self.searchFollowsFolderChanges, var q = location.searchQuery {
            switch target {
            case .folder(let url):
                let recursive = if case .folder(_, let r) = q.scope { r } else { true }
                q.scope = .folder(url, recursive: recursive)
                q.origin = url
                return navigate(to: .search(q))
            case .computer:
                q.scope = .thisMac
                return navigate(to: .search(q))
            case .search:
                break
            }
        }
        navigate(to: target, select: names)
    }

    /// Cmd-Up: the enclosing folder, with the folder we came from selected.
    func goEnclosing() {
        if let origin = location.searchQuery?.origin {
            guard origin.path != "/" else { return jump(to: .computer) }
            return jump(to: .folder(origin.deletingLastPathComponent()))
        }
        guard let url = location.folderURL, url.path != "/" else {
            if case .folder = location { navigate(to: .computer) }
            return
        }
        let isVolumeRoot = details.pathChain.count == 1
        if isVolumeRoot {
            navigate(to: .computer, select: [details.displayName])
        } else {
            navigate(to: .folder(url.deletingLastPathComponent()), select: [url.lastPathComponent])
        }
    }

    func reload() { load() }

    // MARK: Search (DESIGN.md §3.1)

    /// The scope a new search from here gets: the current folder (including subfolders), This Mac
    /// from Computer, and the same scope when refining a search.
    var defaultSearchScope: SearchScope {
        switch location {
        case .folder(let url): .folder(url, recursive: true)
        case .computer: .thisMac
        case .search(let q): q.scope
        }
    }

    /// The folder a search was started from (the scope bar's folder button).
    var searchOrigin: URL? { location.searchQuery?.origin }

    /// Typing in the search field. Starting a search is a history entry; refining it isn't.
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return endSearch() }
        if var q = location.searchQuery {
            guard q.text != text else { return }
            q.text = text
            replaceSearch(q)
        } else {
            navigate(to: .search(SearchQuery(text: text, scope: defaultSearchScope)))
        }
    }

    /// Scope bar changes (scope, subfolders, match mode, kind chips).
    func updateSearch(_ change: (inout SearchQuery) -> Void) {
        guard var q = location.searchQuery else { return }
        change(&q)
        replaceSearch(q)
    }

    private func replaceSearch(_ q: SearchQuery) {
        history.replaceCurrent(.search(q))
        switchTo(.search(q))
    }

    /// Escape or clearing the field: back to the folder, with its selection and scroll restored.
    func endSearch() {
        guard let q = location.searchQuery else { return }
        if history.canGoBack {
            goBack()
        } else if let url = q.origin {
            switchTo(.folder(url))
            history.replaceCurrent(.folder(url))
        }
    }

    private func departingEntry() -> HistoryEntry {
        HistoryEntry(location: location, selectedNames: selectedItems.map(\.name))
    }

    private func switchTo(_ newLocation: Location) {
        location = newLocation
        details = .fallback(newLocation)
        collapseAll()
        selection = []
        focusAnchor = nil
        snapshot = .empty
        // Sorts requested for the previous location may still be running; never show their results.
        appliedGeneration = requestedGeneration
        searchStatus = nil
        settings = AppModel.shared.resolve(newLocation.settingsClass, folder: nil).0
        notify(.location)
        notify(.settings)
        notify(.snapshot)
        load()
    }

    // MARK: Loading

    private func load() {
        loadTask?.cancel()
        rawItems = []
        setLoadState(.loading)
        let location = self.location

        // Folder info (title, path, per-folder settings key) and free space load alongside the
        // listing, never in front of it.
        detailsTask?.cancel()
        detailsTask = Task { [weak self] in
            let details = await LocationInfo.details(for: location)
            guard let self, !Task.isCancelled, self.location == location else { return }
            self.details = details
            self.applyResolvedSettings()
            self.notify(.details)
            let capacity = await LocationInfo.availableCapacity(for: location.folderURL ?? location.searchQuery?.origin ?? URL(fileURLWithPath: "/"))
            guard !Task.isCancelled, self.location == location else { return }
            self.availableCapacity = capacity
            self.notify(.details)
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            switch location {
            case .computer:
                self.rawItems = LocationInfo.volumeItems()
                self.setLoadState(.complete)
                self.rearrange("volumes")
            case .search(let query):
                for await status in SearchEngine.run(query) {
                    if Task.isCancelled { break }
                    self.rawItems = status.items
                    self.searchStatus = status
                    let wasRunning = self.loadState != .complete
                    self.setLoadState(status.isRunning ? .partial(status.items.count) : .complete)
                    if !status.isRunning && wasRunning {
                        self.rearrange("search-complete")
                    } else if Date().timeIntervalSince(self.lastPartialArrange) > 0.15 || !status.isRunning {
                        self.lastPartialArrange = Date()
                        self.rearrange("search")
                    }
                    self.notify(.loadState)
                }
            case .folder(let url):
                for await event in FolderContents.observe(url) {
                    if Task.isCancelled { break }
                    switch event {
                    case .partial(let items):
                        self.rawItems = items
                        self.setLoadState(.partial(items.count))
                        // Throttle re-arranging while a big folder streams in.
                        if Date().timeIntervalSince(self.lastPartialArrange) > 0.15 {
                            self.lastPartialArrange = Date()
                            self.rearrange("partial")
                        }
                    case .complete(let items):
                        self.rawItems = items
                        self.setLoadState(.complete)
                        self.rearrange("complete")
                    case .failed(let error):
                        self.rawItems = []
                        self.setLoadState(.failed(error.localizedDescription, permission: error.isPermissionDenied))
                        self.rearrange("failed")
                    }
                }
            }
        }
    }

    private func setLoadState(_ s: LoadState) {
        guard s != loadState else { return }
        loadState = s
        notify(.loadState)
    }

    private func rearrange(_ reason: String) {
        rearrangeLog.append(reason)
        requestedGeneration += 1
        let generation = requestedGeneration
        let items = rawItems
        var arrangement = settings.arrangement
        // Search results are already filtered for hidden items by the query (hidden:yes).
        if case .search = location { arrangement.showHidden = true }
        Task.detached(priority: .userInitiated) {
            let snap = ArrangementEngine.arrange(items, with: arrangement, generation: generation)
            await self.apply(snap)
        }
    }

    private func apply(_ snap: ItemSnapshot) {
        // Results arrive out of order; never go backwards.
        guard snap.generation > appliedGeneration else { return }
        appliedGeneration = snap.generation
        snapshot = snap
        if !pendingSelection.isEmpty {
            let wanted = Set(pendingSelection)
            let ids = snap.items.filter { wanted.contains($0.name) }.map(\.id)
            if !ids.isEmpty || loadState == .complete {
                selection = Set(ids)
                focusAnchor = ids.first
                pendingSelection = []
            }
        } else {
            // Keep selections inside expanded folders too.
            selection = selection.filter { item($0) != nil }
            if let a = focusAnchor, item(a) == nil { focusAnchor = selection.first }
        }
        notify(.snapshot)
    }

    // MARK: Selection

    /// Called by views. Doesn't notify views back (they already show it).
    func setSelection(_ ids: Set<FileID>, anchor: FileID?) {
        selection = ids
        if let anchor { focusAnchor = anchor } else if !ids.contains(focusAnchor ?? FileID(device: 0, inode: 0)) {
            focusAnchor = ids.first
        }
        notify(.selection)
    }

    // MARK: Settings (DESIGN.md §3.3)

    var isPinned: Bool { AppModel.shared.isPinned(details.folderKey) }

    /// Sort/group/filter changes: re-arrange, keep the selection.
    func updateArrangement(_ change: (inout Arrangement) -> Void) {
        var s = settings
        change(&s.arrangement)
        guard s != settings else { return }
        commit(s)
    }

    /// View-mode and presentation changes: never touch the arrangement, never re-sort.
    func updatePresentation(_ change: (inout Presentation) -> Void) {
        var s = settings
        change(&s.presentation)
        guard s != settings else { return }
        commit(s)
    }

    func togglePin() {
        guard let key = details.folderKey else { return }
        if isPinned { AppModel.shared.unpin(key) } else { AppModel.shared.pin(settings, folder: key) }
    }

    private func commit(_ s: ViewSettings) {
        apply(settings: s)
        AppModel.shared.record(s, cls: location.settingsClass, folder: details.folderKey)
    }

    private func applyResolvedSettings() {
        let (s, source) = AppModel.shared.resolve(location.settingsClass, folder: details.folderKey)
        settingsSource = source
        apply(settings: s)
    }

    private func reresolveSettings() { applyResolvedSettings() }

    private func apply(settings new: ViewSettings) {
        guard new != settings else { return }
        let rearrangeNeeded = new.arrangement != settings.arrangement
        settings = new
        notify(.settings)
        if rearrangeNeeded {
            rearrange("settings")
            for id in children.keys { arrangeChildren(id) }
        }
    }
}
