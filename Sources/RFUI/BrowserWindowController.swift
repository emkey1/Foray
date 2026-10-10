import AppKit
import RFModel
import RFOperations

/// One browser window (= one native tab): sidebar + browser, toolbar, title. In dual-pane mode
/// (DESIGN.md I12) there are two browsers side by side; the sidebar, toolbar and menus act on the
/// active one.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    /// One pane, or two in dual-pane mode (left, right).
    private(set) var panes: [BrowserViewController]
    private(set) var activePaneIndex = 0
    /// The active pane: the one with the focus, which commands act on.
    var browser: BrowserViewController { panes[activePaneIndex] }
    var isDualPane: Bool { panes.count > 1 }
    /// The pane that isn't active (dual-pane mode only).
    var otherPane: BrowserViewController? { isDualPane ? panes[1 - activePaneIndex] : nil }
    /// Asks the window layer to open a location in a new tab (set by WindowManager).
    var openInNewTab: ((Location) -> Void)? {
        didSet { panes.forEach { $0.openInNewTab = openInNewTab } }
    }
    /// Posted (object: the controller) when the active pane changes, so panels can follow it.
    static let activePaneChanged = Notification.Name("ForayActivePaneChanged")
    private var focusObservation: NSKeyValueObservation?
    private var tabKeyMonitor: Any?
    private let sidebar = SidebarViewController()
    private let splitController = NSSplitViewController()
    private var navigationGroup: NSToolbarItemGroup?
    private var modeGroup: NSToolbarItemGroup?
    private var tagsItem: NSMenuToolbarItem?
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
        // Optional (View › Customize Toolbar…).
        static let getInfo = NSToolbarItem.Identifier("getInfo")
        static let share = NSToolbarItem.Identifier("share")
        static let trash = NSToolbarItem.Identifier("trash")
        static let newFolder = NSToolbarItem.Identifier("newFolder")
        static let quickLook = NSToolbarItem.Identifier("quickLook")
        static let tags = NSToolbarItem.Identifier("tags")
        static let eject = NSToolbarItem.Identifier("eject")
        static let connect = NSToolbarItem.Identifier("connect")
        static let inspector = NSToolbarItem.Identifier("inspector")
        static let path = NSToolbarItem.Identifier("copyPath")
        static let rotateLeft = NSToolbarItem.Identifier("rotateLeft")
        static let rotateRight = NSToolbarItem.Identifier("rotateRight")
        static let markup = NSToolbarItem.Identifier("markup")

        /// Simple buttons: (identifier, label, symbol, action).
        @MainActor static let buttons: [(NSToolbarItem.Identifier, String, String, Selector)] = [
            (getInfo, "Get Info", "info.circle", Commands.getInfo),
            (inspector, "Inspector", "sidebar.right", Commands.showInspector),
            (share, "Share", "square.and.arrow.up", Commands.share),
            (trash, "Move to Trash", "trash", Commands.moveToTrash),
            (newFolder, "New Folder", "folder.badge.plus", Commands.newFolder),
            (quickLook, "Quick Look", "eye", Commands.toggleQuickLook),
            (eject, "Eject", "eject", Commands.eject),
            (path, "Copy Path", "doc.on.clipboard", Commands.copyPath),
            (rotateLeft, "Rotate Left", "rotate.left", Commands.rotateLeft),
            (rotateRight, "Rotate Right", "rotate.right", Commands.rotateRight),
            (markup, "Markup", "pencil.tip.crop.circle", Commands.markup),
        ]
    }

    init(location: Location, pendingSearch: SearchQuery? = nil) {
        self.pendingSearch = pendingSearch
        panes = [BrowserViewController(location: location)]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingIdentifier = "Foray.browser"
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
        let paneItem = NSSplitViewItem(viewController: panes[0])
        paneItem.minimumThickness = 240
        splitController.addSplitViewItem(paneItem)
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Foray.browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        sidebar.onNavigate = { [weak self] location in self?.browser.state.jump(to: location) }
        sidebar.onOpenInNewTab = { [weak self] location in WindowManager.shared.openTab(location, nextTo: self) }
        adopt(panes[0])
        // The pane holding the focus is the active one.
        focusObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.focusChanged() }
        }
        syncChrome()
    }

    isolated deinit {
        if let tabKeyMonitor { NSEvent.removeMonitor(tabKeyMonitor) }
    }

    /// The window's chrome follows whichever pane is active.
    private func adopt(_ pane: BrowserViewController) {
        pane.openInNewTab = openInNewTab
        pane.state.observe { [weak self, weak pane] change in
            guard let self, pane === self.browser else { return }
            switch change {
            case .location, .details, .settings: self.syncChrome()
            default: break
            }
        }
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

    // MARK: Dual-pane mode (DESIGN.md I12)

    /// Where the second pane starts, for the session.
    var otherPaneLocation: Location? { isDualPane ? panes[1].state.location : nil }

    /// Shows or hides the second pane. It opens on `location`, or the folder the first is showing.
    /// Hiding keeps the active pane.
    func setDualPane(_ on: Bool, location: Location? = nil) {
        guard on != isDualPane else { return }
        if on {
            let current = browser.state.location
            let start = location ?? (current.searchQuery == nil ? current : .folder(FileManager.default.homeDirectoryForCurrentUser))
            let second = BrowserViewController(location: start)
            panes.append(second)
            adopt(second)
            let item = NSSplitViewItem(viewController: second)
            item.minimumThickness = 240
            splitController.addSplitViewItem(item)
            window?.minSize = NSSize(width: 700, height: 300)
            equalizePanes()
            installTabKeyMonitor()
        } else {
            let closing = panes[1 - activePaneIndex]
            if let item = splitController.splitViewItem(for: closing) { splitController.removeSplitViewItem(item) }
            closing.state.invalidate()
            panes = [browser]
            activePaneIndex = 0
            window?.minSize = NSSize(width: 520, height: 300)
            if let tabKeyMonitor { NSEvent.removeMonitor(tabKeyMonitor) }
            tabKeyMonitor = nil
            window?.makeFirstResponder(browser.content?.firstResponderView)
        }
        activePaneDidChange()
    }

    /// Gives the two panes the same width.
    private func equalizePanes() {
        guard isDualPane else { return }
        let split = splitController.splitView
        split.layoutSubtreeIfNeeded()
        let left = panes[0].view.frame, right = panes[1].view.frame
        guard left.width + right.width > 0 else { return }
        split.setPosition(left.minX + (right.maxX - left.minX - split.dividerThickness) / 2, ofDividerAt: split.arrangedSubviews.count - 2)
    }

    func setActivePane(_ index: Int, focus: Bool = true) {
        guard panes.indices.contains(index) else { return }
        let changed = index != activePaneIndex
        activePaneIndex = index
        if focus { window?.makeFirstResponder(browser.content?.firstResponderView) }
        if changed { activePaneDidChange() }
    }

    private func activePaneDidChange() {
        for (i, pane) in panes.enumerated() {
            pane.paneRole = !isDualPane ? .single : (i == activePaneIndex ? .active : .inactive)
        }
        syncChrome()
        NotificationCenter.default.post(name: Self.activePaneChanged, object: self)
    }

    /// The first responder moved: if it's now inside the other pane, that pane becomes active.
    private func focusChanged() {
        guard isDualPane, let responder = window?.firstResponder else { return }
        var view = responder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor { view = editor.delegate as? NSView }
        guard let view, let index = panes.firstIndex(where: { view.isDescendant(of: $0.view) }) else { return }
        setActivePane(index, focus: false)
    }

    /// Tab moves between the panes, as in other two-pane file managers (only while the focus is
    /// in the file list, so text fields keep their own Tab).
    private func installTabKeyMonitor() {
        guard tabKeyMonitor == nil else { return }
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            let handled = MainActor.assumeIsolated {
                guard let self, self.handlesTabKey(event) else { return false }
                self.switchPane(nil)
                return true
            }
            return handled ? nil : event
        }
    }

    func handlesTabKey(_ event: NSEvent) -> Bool {
        guard isDualPane, event.keyCode == 48, event.window === window, window?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let responder = window?.firstResponder as? NSView, !(responder is NSText) else { return false }
        return panes.contains { responder.isDescendant(of: $0.view) }
    }

    @objc func toggleDualPane(_ sender: Any?) {
        setDualPane(!isDualPane)
        WindowManager.shared.sessionChanged()
    }

    @objc func switchPane(_ sender: Any?) {
        guard isDualPane else { return }
        setActivePane(1 - activePaneIndex)
    }

    /// The active pane's selection goes into the folder the other pane shows.
    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(move: true) }

    private func transferToOtherPane(move: Bool) {
        guard let other = otherPane, let folder = other.state.location.folderURL else { return }
        let urls = browser.state.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        // The other pane started it as far as results go: the new items are selected there.
        FileOperationsUI.shared.submit(move ? .move(urls, to: folder) : .copy(urls, to: folder), from: other.state)
    }

    /// Shows the selected folder (or, with nothing selected, this pane's folder) in the other pane.
    @objc func openInOtherPane(_ sender: Any?) {
        guard let other = otherPane else { return }
        let selected = browser.state.selectedItems
        if selected.count == 1, selected[0].isNavigableFolder {
            other.state.jump(to: .folder(selected[0].url))
        } else if selected.isEmpty {
            other.state.jump(to: browser.state.location)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleDualPane(_:)):
            item.title = isDualPane ? "Hide Second Pane" : "Show Second Pane"
            return true
        case #selector(switchPane(_:)):
            return isDualPane
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return otherPane?.state.location.folderURL != nil && !browser.state.selectedItems.isEmpty
        case #selector(openInOtherPane(_:)):
            let selected = browser.state.selectedItems
            return isDualPane && (selected.isEmpty || (selected.count == 1 && selected[0].isNavigableFolder))
        default:
            return true
        }
    }

    // MARK: Tabs

    override func newWindowForTab(_ sender: Any?) {
        WindowManager.shared.openTab(browser.state.location, nextTo: self)
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.state.invalidate() }
        WindowManager.shared.closed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { WindowManager.shared.sessionChanged() }

    /// Spring-loaded tabs: when the tabs change, let the tab buttons take part in file drags.
    private var tabSignature = ""
    func windowDidUpdate(_ notification: Notification) {
        let group = window?.tabGroup
        let signature = "\(group?.windows.count ?? 0)/\(group?.isTabBarVisible ?? false)"
        guard signature != tabSignature else { return }
        tabSignature = signature
        SpringLoadedTabs.enable(in: window)
    }

    /// One app-wide undo stack for file operations, like Finder.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { OperationCenter.shared.undoManager }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.navigation, .flexibleSpace, ToolbarID.mode, ToolbarID.arrange,
         ToolbarID.jobs, ToolbarID.search, ToolbarID.guide]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + ToolbarID.buttons.map(\.0) + [ToolbarID.tags, ToolbarID.connect, .space, .flexibleSpace]
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
            let button = JobsToolbarButton()
            item.view = button
            item.label = "Operations"
            button.toolbarItem = item
            return item
        case ToolbarID.guide:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Guide")
            item.label = "Guide"
            item.toolTip = "Open the Foray Guide (⌘?)"
            item.target = self
            item.action = #selector(openGuide(_:))
            return item
        case let id where ToolbarID.buttons.contains { $0.0 == id }:
            let spec = ToolbarID.buttons.first { $0.0 == id }!
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: spec.2, accessibilityDescription: spec.1)
            item.label = spec.1
            item.toolTip = spec.1
            item.action = spec.3   // nil target: the front browser handles it (and validates it)
            return item
        case ToolbarID.connect:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Connect to Server")
            item.label = "Connect"
            item.toolTip = "Connect to Server (⌘K)"
            item.target = self
            item.action = #selector(connectToServer(_:))
            return item
        case ToolbarID.tags:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Tags")
            item.label = "Tags"
            item.toolTip = "Tag the selection"
            item.menu = NSMenu()
            item.menu.delegate = self
            item.showsIndicator = true
            tagsItem = item
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

    @objc private func connectToServer(_ sender: Any?) { ConnectToServerWindowController.shared.show() }

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
        guard let mode = ViewMode.allCases[safe: group.selectedIndex] else {
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
        let controller = make(location ?? AppSettings.newWindowLocation)
        controller.window?.center()
        showAsSeparateWindow(controller)
    }

    /// Items handed to Foray by other apps: "Show in Finder" (when Foray is the file viewer),
    /// `open -a Foray`, drops on the Dock icon. Folders open; files are shown selected in their
    /// folder (one tab per folder). Returns the tabs it opened.
    public func reveal(_ urls: [URL]) { revealing(urls) }

    /// A new window at `location`, with `names` selected (from the desktop).
    func open(_ location: Location, select names: [String]) {
        openWindow(location)
        if !names.isEmpty { controllers.last?.browser.state.select(names: names) }
        NSApplication.shared.activate()
    }

    /// `openFolders: false` shows folders selected in their parent too, instead of opening them.
    @discardableResult
    func revealing(_ urls: [URL], openFolders: Bool = true) -> [BrowserWindowController] {
        var folders: [URL] = []
        var selections: [URL: [String]] = [:]
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            if isDir.boolValue && !isPackage && (openFolders || url.path == "/") {
                if !folders.contains(url) { folders.append(url) }
            } else {
                let parent = url.deletingLastPathComponent()
                if selections[parent] == nil { folders.append(parent) }
                selections[parent, default: []].append(url.lastPathComponent)
            }
        }
        var opened: [BrowserWindowController] = []
        for folder in folders {
            let anchor = NSApplication.shared.keyWindow?.windowController as? BrowserWindowController
            if let anchor { openTab(.folder(folder), nextTo: anchor) } else { openWindow(.folder(folder)) }
            guard let controller = controllers.last else { continue }
            if let names = selections[folder] { controller.browser.state.select(names: names) }
            opened.append(controller)
        }
        NSApplication.shared.activate()
        return opened
    }

    /// The browser window in front (the last one opened if none is main).
    var frontController: BrowserWindowController? {
        (NSApplication.shared.mainWindow?.windowController as? BrowserWindowController) ?? controllers.last
    }

    /// Shows `location` in the front browser window, or a new window if there's none.
    public func show(_ location: Location) {
        let front = frontController
        if let front, front.window?.isVisible == true {
            front.browser.state.jump(to: location)
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(location)
        }
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
        controller.openInNewTab = { [weak self, weak controller] location in
            if AppSettings.openFoldersInTabs { self?.openTab(location, nextTo: controller) } else { self?.openWindow(location) }
        }
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
                // The tab is its first (left) pane; a second pane is saved alongside.
                if let pending = c.pendingSearch, c.browser.state.location.searchQuery == nil, !c.isDualPane { return .search(pending) }
                return c.panes[0].state.location
            }
            let selected = group.firstIndex { $0 == window.tabGroup?.selectedWindow } ?? 0
            let second = group.compactMap { w in controllers.first { $0.window === w } }.map(\.otherPaneLocation)
            windows.append(.init(tabs: tabs, selectedTab: selected, frame: NSStringFromRect(window.frame),
                                 otherPanes: second.contains { $0 != nil } ? second : nil))
        }
        AppModel.shared.saveSession(AppModel.Session(windows: windows))
    }

    /// Reopens the saved windows and tabs; returns false if there was nothing to restore.
    public func restoreSession() -> Bool {
        FileOperationsUI.shared.install()
        guard let session = AppModel.shared.loadSession(), !session.windows.isEmpty else { return false }
        for saved in session.windows where !saved.tabs.isEmpty {
            // The second pane of tab `i`, if it had one (a search there comes back as its folder).
            func restorePanes(_ c: BrowserWindowController, _ i: Int) {
                guard let other = saved.otherPanes?[safe: i], let location = other else { return }
                c.setDualPane(true, location: location.searchQuery.map { $0.origin.map(Location.folder) ?? .computer } ?? location)
            }
            let first = make(saved.tabs[0])
            if let frame = saved.frame { first.window?.setFrame(NSRectFromString(frame), display: false) }
            showAsSeparateWindow(first)
            restorePanes(first, 0)
            var tabWindows = [first.window!]
            for (i, location) in saved.tabs.enumerated().dropFirst() {
                let c = make(location)
                first.window?.addTabbedWindow(c.window!, ordered: .above)
                restorePanes(c, i)
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

/// The Tags toolbar menu is rebuilt for the current selection each time it opens.
extension BrowserWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !browser.state.selectedItems.isEmpty, let tags = browser.tagsMenuItem().submenu else {
            menu.addItem(NSMenuItem(title: "Select items to tag them", action: nil, keyEquivalent: ""))
            return
        }
        for item in tags.items {
            tags.removeItem(item)
            if item.action != nil && item.target == nil { item.target = browser }
            menu.addItem(item)
        }
    }
}
