import AppKit
import RFModel
import RFOperations

/// One browser window (= one native tab): sidebar + browser, toolbar, title.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let browser: BrowserViewController
    private let sidebar = SidebarViewController()
    private let splitController = NSSplitViewController()
    private var navigationGroup: NSToolbarItemGroup?
    private var modeGroup: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?
    private var recentsObserver: UUID?
    /// A search shown in the field but not running (restored at launch, or the most recent one).
    /// Return runs it exactly as saved; editing the text starts a new search here instead.
    var pendingSearch: SearchQuery? {
        didSet { syncSearchField() }
    }

    private enum ToolbarID {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let mode = NSToolbarItem.Identifier("viewMode")
        static let arrange = NSToolbarItem.Identifier("arrange")
        static let search = NSToolbarItem.Identifier("search")
        static let guide = NSToolbarItem.Identifier("guide")
        static let jobs = NSToolbarItem.Identifier("jobs")
    }

    init(location: Location, pendingSearch: SearchQuery? = nil) {
        self.pendingSearch = pendingSearch
        browser = BrowserViewController(location: location)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingIdentifier = "RealFinder.browser"
        // .automatic: tabs only when asked (⌘T, the tab bar's +) or when the user's system
        // setting prefers tabs. (.preferred merged every new window into a tab.)
        window.tabbingMode = .automatic
        window.titlebarSeparatorStyle = .automatic
        window.minSize = NSSize(width: 520, height: 300)
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: browser))
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.delegate = self

        let toolbar = NSToolbar(identifier: "RealFinder.browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        sidebar.onNavigate = { [weak self] location in self?.browser.state.jump(to: location) }
        sidebar.onOpenInNewTab = { [weak self] location in WindowManager.shared.openTab(location, nextTo: self) }
        browser.state.observe { [weak self] change in
            switch change {
            case .location, .details, .settings: self?.syncChrome()
            default: break
            }
        }
        syncChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Title, proxy icon, sidebar highlight and toolbar state follow the browser.
    private func syncChrome() {
        let state = browser.state
        window?.title = state.details.displayName
        window?.representedURL = state.location.folderURL
        sidebar.highlight(state.location)
        navigationGroup?.subitems[0].isEnabled = state.history.canGoBack
        navigationGroup?.subitems[1].isEnabled = state.history.canGoForward
        if let modeGroup, let i = ViewMode.allCases.firstIndex(of: state.settings.presentation.mode) {
            modeGroup.selectedIndex = i
        }
        syncSearchField()
        WindowManager.shared.sessionChanged()
    }

    // MARK: Tabs

    override func newWindowForTab(_ sender: Any?) {
        WindowManager.shared.openTab(browser.state.location, nextTo: self)
    }

    func windowWillClose(_ notification: Notification) {
        browser.state.invalidate()
        WindowManager.shared.closed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { WindowManager.shared.sessionChanged() }

    /// One app-wide undo stack for file operations, like Finder.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { OperationCenter.shared.undoManager }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.navigation, .flexibleSpace, ToolbarID.mode, ToolbarID.arrange,
         ToolbarID.jobs, ToolbarID.search, ToolbarID.guide]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.navigation:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                         NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!],
                selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navigationClicked(_:)))
            group.label = "Back/Forward"
            group.isNavigational = true
            navigationGroup = group
            return group
        case ToolbarID.mode:
            let symbols = ["square.grid.2x2", "list.bullet", "rectangle.split.3x1", "rectangle.grid.1x2"]
            let group = NSToolbarItemGroup(
                itemIdentifier: id, images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! },
                selectionMode: .selectOne, labels: ViewMode.allCases.map(\.title), target: self, action: #selector(modeClicked(_:)))
            group.label = "View"
            for i in [2, 3] {  // column and gallery views arrive in milestone M4
                group.subitems[i].isEnabled = false
                group.subitems[i].toolTip = "\(ViewMode.allCases[i].title) view isn't available yet"
            }
            modeGroup = group
            return group
        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            item.preferredWidthForSearchField = 220
            searchItem = item
            updateRecentsMenu()
            recentsObserver = AppModel.shared.observeRecentSearches { [weak self] in self?.updateRecentsMenu() }
            syncSearchField()
            return item
        case ToolbarID.jobs:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = JobsToolbarButton()
            item.label = "Operations"
            return item
        case ToolbarID.guide:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Guide")
            item.label = "Guide"
            item.toolTip = "Open the RealFinder Guide (⌘?)"
            item.target = self
            item.action = #selector(openGuide(_:))
            return item
        case ToolbarID.arrange:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort and Group")
            item.label = "Sort"
            item.toolTip = "Sort, group and filter by kind"
            item.menu = Menus.arrangementMenu()
            item.showsIndicator = true
            return item
        default:
            return nil
        }
    }

    @objc private func openGuide(_ sender: Any?) {
        GuideWindowController.shared.show(browser.state.location.searchQuery != nil ? .search : .top)
    }

    // MARK: Search (DESIGN.md §3.1)

    /// ⌘F: focus the search field. Searches start in the current folder.
    @objc func focusSearch(_ sender: Any?) {
        guard let searchItem else { return }
        searchItem.beginSearchInteraction()
        window?.makeFirstResponder(searchItem.searchField)
    }

    @objc private func searchFieldChanged(_ field: NSSearchField) {
        if let pending = pendingSearch, field.stringValue == pending.text { return }  // shown, not edited
        pendingSearch = nil
        browser.state.search(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return on a restored/recent search runs it exactly as saved (scope and match mode).
            guard let pending = pendingSearch, searchItem?.searchField.stringValue == pending.text else { return false }
            pendingSearch = nil
            browser.state.runSearch(pending)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape ends the search and returns focus to the files.
            pendingSearch = nil
            searchItem?.searchField.stringValue = ""
            browser.state.endSearch()
            searchItem?.endSearchInteraction()
            window?.makeFirstResponder(browser.view)
            return true
        default:
            return false
        }
    }

    // MARK: Recent searches (the field's magnifying-glass menu)

    private func updateRecentsMenu() {
        guard let field = searchItem?.searchField else { return }
        let menu = NSMenu(title: "Recent Searches")
        let recents = AppModel.shared.recentSearches
        let header = NSMenuItem(title: recents.isEmpty ? "No Recent Searches" : "Recent Searches", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (i, q) in recents.enumerated() {
            let item = NSMenuItem(title: Self.title(for: q), action: #selector(recentSearchChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.toolTip = q.scope.folderURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "This Mac"
            menu.addItem(item)
        }
        if !recents.isEmpty {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Recent Searches", action: #selector(clearRecentSearches(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        field.searchMenuTemplate = menu
    }

    static func title(for q: SearchQuery) -> String {
        let place = switch q.scope {
        case .thisMac: "This Mac"
        case .folder(let url, let recursive): FileManager.default.displayName(atPath: url.path) + (recursive ? "" : " (top level)")
        }
        return "\(q.text)  —  \(place)" + (q.match == .namesAndContents ? ", names & contents" : "")
    }

    @objc private func recentSearchChosen(_ sender: NSMenuItem) {
        guard let q = AppModel.shared.recentSearches[safe: sender.tag] else { return }
        pendingSearch = nil
        searchItem?.searchField.stringValue = q.text
        browser.state.runSearch(q)
    }

    @objc private func clearRecentSearches(_ sender: Any?) { AppModel.shared.clearRecentSearches() }

    /// Keeps the field's text and placeholder in step with the tab (e.g. after Back).
    private func syncSearchField() {
        guard let field = searchItem?.searchField else { return }
        let state = browser.state
        // Never overwrite text the user is still typing; chips and Back change it while unfocused.
        if field.currentEditor() == nil {
            let text = state.location.searchQuery?.text ?? pendingSearch?.text ?? ""
            if field.stringValue != text { field.stringValue = text }
        }
        field.toolTip = pendingSearch.map { "Press Return to search again: \(Self.title(for: $0))" }
        let place: String = switch state.defaultSearchScope {
        case .thisMac: "This Mac"
        case .folder(let url, _): FileManager.default.displayName(atPath: url.path)
        }
        field.placeholderString = "Search “\(place)”"
    }

    @objc private func navigationClicked(_ group: NSToolbarItemGroup) {
        if group.selectedIndex == 0 { browser.goBack(nil) } else { browser.goForward(nil) }
    }

    @objc private func modeClicked(_ group: NSToolbarItemGroup) {
        guard let mode = ViewMode.allCases[safe: group.selectedIndex], mode == .icon || mode == .list else {
            syncChrome()
            return
        }
        browser.state.updatePresentation { $0.mode = mode }
    }
}

/// Owns browser windows, opens tabs and saves/restores the session (DESIGN.md §4.1).
@MainActor
public final class WindowManager {
    public static let shared = WindowManager()

    private var controllers: [BrowserWindowController] = []
    var controllersForTesting: [BrowserWindowController] { controllers }

    init() {}
    private var isTerminating = false
    private var saveScheduled = false

    public func openWindow(_ location: Location? = nil) {
        FileOperationsUI.shared.install()
        let controller = make(location ?? .folder(FileManager.default.homeDirectoryForCurrentUser))
        controller.window?.center()
        showAsSeparateWindow(controller)
    }

    /// New Window means a window, even when the system setting prefers tabs.
    private func showAsSeparateWindow(_ controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        window.tabbingMode = .disallowed
        controller.showWindow(nil)
        window.tabbingMode = .automatic
    }

    /// Opens a tab next to `existing` (or in the key window).
    public func openTab(_ location: Location, nextTo existing: NSWindowController? = nil) {
        let anchor = existing?.window ?? NSApp.keyWindow
        let controller = make(location)
        guard let anchor, let window = controller.window else { return controller.showWindow(nil) }
        anchor.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    private func make(_ location: Location) -> BrowserWindowController {
        // Searches are never re-run on their own (e.g. at launch): the tab opens on the folder the
        // search started from, with the search in the field, ready for Return.
        var start = location
        var pending: SearchQuery?
        if let q = location.searchQuery {
            pending = q
            start = q.origin.map(Location.folder) ?? .computer
            AppModel.shared.recordSearch(q)   // and keep it in Recent Searches
        }
        let controller = BrowserWindowController(location: start, pendingSearch: pending)
        controller.browser.openInNewTab = { [weak self, weak controller] location in self?.openTab(location, nextTo: controller) }
        controllers.append(controller)
        return controller
    }

    func closed(_ controller: BrowserWindowController) {
        guard !isTerminating else { return }
        controllers.removeAll { $0 === controller }
        sessionChanged()
    }

    // MARK: Session

    func sessionChanged() {
        guard !isTerminating, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                self.saveScheduled = false
                self.saveSession()
            }
        }
    }

    public func prepareForTermination() {
        for c in controllers { c.browser.state.recordSearchIfLeaving() }
        saveSession()
        isTerminating = true
        AppModel.shared.flush()
    }

    private func saveSession() {
        var seen = Set<ObjectIdentifier>()
        var windows: [AppModel.Session.Window] = []
        for controller in controllers {
            guard let window = controller.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let group = window.tabbedWindows ?? [window]
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            // A tab with a search waiting in its field saves the search, so it waits again next launch.
            let tabs = group.compactMap { w -> Location? in
                guard let c = controllers.first(where: { $0.window === w }) else { return nil }
                if let pending = c.pendingSearch, c.browser.state.location.searchQuery == nil { return .search(pending) }
                return c.browser.state.location
            }
            let selected = group.firstIndex { $0 == window.tabGroup?.selectedWindow } ?? 0
            windows.append(.init(tabs: tabs, selectedTab: selected, frame: NSStringFromRect(window.frame)))
        }
        AppModel.shared.saveSession(AppModel.Session(windows: windows))
    }

    /// Reopens the saved windows and tabs; returns false if there was nothing to restore.
    public func restoreSession() -> Bool {
        FileOperationsUI.shared.install()
        guard let session = AppModel.shared.loadSession(), !session.windows.isEmpty else { return false }
        for saved in session.windows where !saved.tabs.isEmpty {
            let first = make(saved.tabs[0])
            if let frame = saved.frame { first.window?.setFrame(NSRectFromString(frame), display: false) }
            showAsSeparateWindow(first)
            var tabWindows = [first.window!]
            for location in saved.tabs.dropFirst() {
                let c = make(location)
                first.window?.addTabbedWindow(c.window!, ordered: .above)
                tabWindows.append(c.window!)
            }
            tabWindows[safe: saved.selectedTab]?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// At launch: if no restored tab has a search waiting, put the most recent search in the key
    /// window's field (not running; Return runs it).
    public func prefillMostRecentSearch() {
        guard !controllers.contains(where: { $0.pendingSearch != nil }),
              let recent = AppModel.shared.recentSearches.first else { return }
        let key = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first
        key?.pendingSearch = recent
    }
}
