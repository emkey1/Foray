import AppKit
import Quartz
import RFFileSystem
import RFModel

/// One tab's browser: hosts the current content view, path bar and status bar, and implements the
/// commands (menus, keyboard, Quick Look) that every view mode shares.
@MainActor
final class BrowserViewController: NSViewController, ContentHost, NSMenuItemValidation {
    let state: BrowserState
    /// Asks the window layer to open a location in a new tab.
    var openInNewTab: ((Location) -> Void)?

    private let contentContainer = NSView()
    private let scopeBar = SearchScopeBar()
    private var scopeBarCollapsed: NSLayoutConstraint?
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let pathBar = NSPathControl()
    private let addressField = AddressField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 64, minValue: 16, maxValue: 256, target: nil, action: nil)
    private var content: ContentView?
    private var contentMode: ViewMode?
    private var typeSelect = TypeSelectBuffer()
    private var previewPanel: QLPreviewPanel?

    init(location: Location) {
        state = BrowserState(location: location)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { MainActor.assumeIsolated { state.invalidate() } }

    override func loadView() {
        let root = NSView()

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true

        pathBar.pathStyle = .standard
        pathBar.controlSize = .small
        pathBar.focusRingType = .none
        pathBar.target = self
        pathBar.action = #selector(pathBarClicked)
        pathBar.doubleAction = #selector(beginEditingPath)
        pathBar.toolTip = "Double-click or press ⇧⌘G to type a path"

        addressField.isHidden = true
        addressField.controlSize = .small
        addressField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addressField.placeholderString = "Enter a path (Tab completes, Esc cancels)"
        addressField.onCommit = { [weak self] text in self?.commitAddress(text) }
        addressField.onCancel = { [weak self] in self?.endEditingPath() }

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        sizeSlider.controlSize = .mini
        sizeSlider.target = self
        sizeSlider.action = #selector(iconSizeChanged)

        scopeBar.onChange = { [weak self] change in self?.state.updateSearch(change) }
        let views: [NSView] = [scopeBar, contentContainer, messageLabel, pathBar, addressField, statusLabel, sizeSlider]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        scopeBarCollapsed = scopeBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scopeBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scopeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: scopeBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: separator.topAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -60),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: pathBar.topAnchor, constant: -2),

            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            pathBar.heightAnchor.constraint(equalToConstant: 20),
            pathBar.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            addressField.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            addressField.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            addressField.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 120),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -120),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),

            sizeSlider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sizeSlider.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 90),
        ])
        view = root

        state.observe { [weak self] change in self?.stateChanged(change) }
        installContent()
        refreshAll()
    }

    // MARK: State → UI

    private func stateChanged(_ change: BrowserState.Change) {
        switch change {
        case .settings:
            installContent()
            content?.apply(state.snapshot, settings: state.settings)
            restoreSelection()
            updateStatus()
        case .snapshot:
            content?.apply(state.snapshot, settings: state.settings)
            restoreSelection()
            updateStatus()
            updateMessage()
            previewPanel?.reloadData()
        case .loadState:
            updateMessage()
            updateStatus()
        case .details, .location:
            updatePathBar()
            updateStatus()
            updateScopeBar()
        case .selection:
            updateStatus()
            previewPanel?.reloadData()
        }
    }

    private func updateScopeBar() {
        if let q = state.location.searchQuery {
            scopeBar.show(q)
            scopeBar.isHidden = false
            scopeBarCollapsed?.isActive = false
        } else {
            scopeBar.isHidden = true
            scopeBarCollapsed?.isActive = true
        }
    }

    private func refreshAll() {
        updateScopeBar()
        content?.apply(state.snapshot, settings: state.settings)
        restoreSelection()
        updatePathBar()
        updateStatus()
        updateMessage()
    }

    /// Swaps the content view when the mode changes. Same snapshot, same selection (§3.3 rule 1–2).
    private func installContent() {
        var mode = state.settings.presentation.mode
        if mode == .column || mode == .gallery { mode = .list }  // M4
        guard mode != contentMode else { return }
        let hadFocus = view.window?.firstResponder === content?.firstResponderView
        content?.view.removeFromSuperview()
        content?.removeFromParent()

        let new: ContentView = mode == .icon ? IconContentViewController() : ListContentViewController()
        new.host = self
        addChild(new)
        new.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(new.view)
        NSLayoutConstraint.activate([
            new.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            new.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            new.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            new.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        content = new
        contentMode = mode
        sizeSlider.isHidden = mode != .icon
        sizeSlider.doubleValue = state.settings.presentation.icon.iconSize
        if hadFocus || view.window != nil { view.window?.makeFirstResponder(new.firstResponderView) }
    }

    private func restoreSelection() {
        content?.showSelection(state.selection, reveal: state.focusAnchor)
    }

    private func updatePathBar() {
        let chain = state.details.pathChain
        pathBar.pathItems = chain.map { entry in
            let item = NSPathControlItem()
            item.title = entry.name
            item.image = NSWorkspace.shared.icon(for: entry.url.path == "/" || chain.first?.url == entry.url ? .volume : .folder)
            return item
        }
        if chain.isEmpty {
            let item = NSPathControlItem()
            item.title = state.details.displayName
            pathBar.pathItems = [item]
        }
    }

    private func updateStatus() {
        let snap = state.snapshot
        if let search = state.searchStatus {
            var parts = [search.isRunning ? "Searching… \(search.items.count.formatted()) found" : "\(snap.items.count.formatted()) found"]
            if search.foldersScanned > 0 { parts.append("\(search.foldersScanned.formatted()) folders scanned") }
            if search.foldersSkipped > 0 { parts.append("\(search.foldersSkipped.formatted()) couldn't be read") }
            if !state.selectedItems.isEmpty { parts.append("\(state.selectedItems.count.formatted()) selected") }
            statusLabel.stringValue = parts.joined(separator: "  ·  ")
            return
        }
        var parts: [String] = []
        let selected = state.selectedItems
        if selected.isEmpty {
            parts.append(Formatting.itemCount(snap.items.count))
        } else {
            let bytes = selected.compactMap { $0.isNavigableFolder ? nil : $0.size }.reduce(0, +)
            parts.append("\(selected.count.formatted()) of \(snap.items.count.formatted()) selected" + (bytes > 0 ? ", \(Formatting.size(bytes))" : ""))
        }
        if snap.totalCount > snap.items.count { parts.append("\((snap.totalCount - snap.items.count).formatted()) hidden") }
        if let free = state.details.availableCapacity { parts.append("\(Formatting.size(free)) available") }
        if case .partial(let n) = state.loadState { parts.append("loading \(n.formatted())…") }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    private func updateMessage() {
        switch state.loadState {
        case .failed(let message, _):
            messageLabel.stringValue = message
            messageLabel.isHidden = false
        case .complete where state.snapshot.items.isEmpty && state.location.searchQuery != nil:
            let q = state.location.searchQuery!
            let place = q.scope == .thisMac ? "on this Mac" : "in “\(q.scope.folderURL?.lastPathComponent ?? "")”"
            messageLabel.stringValue = "No results for “\(q.text)” \(place)."
            messageLabel.isHidden = false
        case .complete where state.snapshot.items.isEmpty && !state.settings.arrangement.kindFilter.isEmpty:
            messageLabel.stringValue = "No items match the kind filter."
            messageLabel.isHidden = false
        default:
            messageLabel.isHidden = true
        }
    }

    // MARK: ContentHost

    func contentSelectionChanged(_ ids: Set<FileID>, anchor: FileID?) {
        state.setSelection(ids, anchor: anchor)
    }

    func contentOpen(_ ids: [FileID], inNewTab: Bool) {
        open(ids.compactMap(state.snapshot.item), inNewTab: inNewTab)
    }

    func contentMenu(clicked: FileID?) -> NSMenu? {
        let menu = NSMenu()
        let items = state.selectedItems
        if items.isEmpty {
            menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
                .state = state.settings.arrangement.showHidden ? .on : .off
            menu.addItem(sortMenuItem())
            return menu
        }
        menu.addItem(withTitle: "Open", action: #selector(openSelection(_:)), keyEquivalent: "")
        if items.allSatisfy(\.isNavigableFolder) {
            menu.addItem(withTitle: "Open in New Tab", action: #selector(openSelectionInNewTab(_:)), keyEquivalent: "")
        }
        if let openWith = openWithMenuItem(for: items) { menu.addItem(openWith) }
        if items.count == 1, items[0].flags.contains(.package) {
            menu.addItem(withTitle: "Show Package Contents", action: #selector(showPackageContents(_:)), keyEquivalent: "")
        }
        if state.location.searchQuery != nil && items.count == 1 {
            menu.addItem(withTitle: "Show in Enclosing Folder", action: #selector(showInEnclosingFolder(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quick Look", action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        return menu
    }

    func contentToggleQuickLook() { toggleQuickLook(nil) }

    func contentTypeSelect(_ characters: String) {
        guard let id = typeSelect.add(characters, in: state.snapshot) else { return }
        state.setSelection([id], anchor: id)
        content?.showSelection([id], reveal: id)
    }

    func contentHeaderClicked(_ key: SortKey, shift: Bool) {
        state.updateArrangement { shift ? $0.toggleSecondary(key) : $0.setPrimary(key) }
    }

    func contentPresentationChanged(_ change: (inout Presentation) -> Void) {
        state.updatePresentation(change)
    }

    // MARK: Opening

    func open(_ items: [FileItem], inNewTab: Bool) {
        let folders = items.filter(\.isNavigableFolder)
        let files = items.filter { !$0.isNavigableFolder }
        if folders.count == 1 && files.isEmpty && !inNewTab {
            state.navigate(to: .folder(folders[0].url))
        } else {
            for f in folders { openInNewTab?(.folder(f.url)) }
        }
        for f in files { NSWorkspace.shared.open(f.url) }
    }

    @objc func openSelection(_ sender: Any?) { open(state.selectedItems, inNewTab: false) }
    @objc func openSelectionInNewTab(_ sender: Any?) { open(state.selectedItems, inNewTab: true) }

    /// From search results: go to the item's folder with the item selected (Back returns to results).
    @objc func showInEnclosingFolder(_ sender: Any?) {
        guard let item = state.selectedItems.first else { return }
        state.navigate(to: .folder(item.url.deletingLastPathComponent()), select: [item.name])
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let item = state.selectedItems.first else { return }
        state.navigate(to: .folder(item.url))
    }

    private func openWithMenuItem(for items: [FileItem]) -> NSMenuItem? {
        guard let first = items.first, !first.isNavigableFolder else { return nil }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
        guard !apps.isEmpty else { return nil }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first.url)
        let submenu = NSMenu()
        for app in apps.prefix(20) {
            let name = FileManager.default.displayName(atPath: app.path)
            let mi = NSMenuItem(title: app == defaultApp ? "\(name) (default)" : name, action: #selector(openWithApp(_:)), keyEquivalent: "")
            mi.representedObject = app
            mi.image = NSWorkspace.shared.icon(forFile: app.path)
            mi.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(mi)
            if app == defaultApp && apps.count > 1 { submenu.addItem(.separator()) }
        }
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(state.selectedItems.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = state.selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: Navigation commands

    @objc func goBack(_ sender: Any?) { state.goBack() }
    @objc func goForward(_ sender: Any?) { state.goForward() }
    @objc func goEnclosing(_ sender: Any?) { state.goEnclosing() }
    @objc func reloadFolder(_ sender: Any?) { state.reload() }

    @objc func goToStandardLocation(_ sender: NSMenuItem) {
        if sender.tag == StandardLocation.computer.rawValue { return state.jump(to: .computer) }
        guard let location = StandardLocation(rawValue: sender.tag), let url = location.url else { return }
        state.jump(to: .folder(url))
    }

    @objc private func pathBarClicked() {
        guard let clicked = pathBar.clickedPathItem, let i = pathBar.pathItems.firstIndex(of: clicked),
              i < state.details.pathChain.count else { return }
        let target = state.details.pathChain[i].url
        let child = i + 1 < state.details.pathChain.count ? state.details.pathChain[i + 1].url.lastPathComponent : nil
        state.jump(to: .folder(target), select: child.map { [$0] } ?? [])
    }

    // MARK: Go to Folder (inline address field, DESIGN.md I2)

    @objc func goToFolder(_ sender: Any?) { beginEditingPath() }

    @objc private func beginEditingPath() {
        addressField.stringValue = state.location.folderURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "~"
        pathBar.isHidden = true
        addressField.isHidden = false
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    private func endEditingPath() {
        addressField.isHidden = true
        pathBar.isHidden = false
        if let content { view.window?.makeFirstResponder(content.firstResponderView) }
    }

    private func commitAddress(_ text: String) {
        let expanded = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let base = state.location.folderURL ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
        endEditingPath()
        Task {
            // Off-main check: a folder navigates; a file reveals it in its folder.
            guard let item = await Task.detached(operation: { DirectoryLoader.shared.stat(url.standardizedFileURL) }).value else {
                NSSound.beep()
                return
            }
            if item.isNavigableFolder || item.flags.contains(.mountPoint) {
                state.jump(to: .folder(item.url))
            } else {
                state.jump(to: .folder(item.url.deletingLastPathComponent()), select: [item.name])
            }
        }
    }

    // MARK: View commands

    @objc func setViewMode(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSToolbarItemGroup)?.selectedIndex ?? 0
        guard let mode = ViewMode.allCases[safe: tag], mode == .icon || mode == .list else { return }
        state.updatePresentation { $0.mode = mode }
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let key = SortKey.allCases[safe: sender.tag] else { return }
        state.updateArrangement { $0.setPrimary(key) }
    }

    @objc func groupBy(_ sender: NSMenuItem) {
        let key = sender.tag < 0 ? nil : GroupKey.allCases[safe: sender.tag]
        state.updateArrangement { $0.groupBy = key }
    }

    @objc func filterByKind(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return state.updateArrangement { $0.kindFilter = [] }
        }
        state.updateArrangement { a in
            if a.kindFilter.contains(id) { a.kindFilter.remove(id) } else { a.kindFilter.insert(id) }
        }
    }

    @objc func toggleFoldersFirst(_ sender: Any?) { state.updateArrangement { $0.foldersFirst.toggle() } }
    @objc func toggleHiddenFiles(_ sender: Any?) { state.updateArrangement { $0.showHidden.toggle() } }
    @objc func toggleRememberSettings(_ sender: Any?) { state.togglePin() }
    @objc func toggleRelativeDates(_ sender: Any?) { state.updatePresentation { $0.list.relativeDates.toggle() } }

    @objc private func iconSizeChanged() {
        let size = (sizeSlider.doubleValue / 8).rounded() * 8
        state.updatePresentation { $0.icon.iconSize = size }
    }

    func sortMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        item.submenu = Menus.sortMenu()
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let a = state.settings.arrangement
        switch item.action {
        case #selector(goBack(_:)): return state.history.canGoBack
        case #selector(goForward(_:)): return state.history.canGoForward
        case #selector(goEnclosing(_:)): return state.location != .computer
        case #selector(showInEnclosingFolder(_:)):
            return state.location.searchQuery != nil && state.selectedItems.count == 1
        case #selector(openSelection(_:)), #selector(copyPath(_:)), #selector(openSelectionInNewTab(_:)):
            return !state.selectedItems.isEmpty
        case #selector(toggleQuickLook(_:)): return !state.selectedItems.isEmpty || previewPanel != nil
        case #selector(setViewMode(_:)):
            item.state = item.tag == ViewMode.allCases.firstIndex(of: state.settings.presentation.mode) ? .on : .off
            return item.tag <= 1
        case #selector(sortBy(_:)):
            let key = SortKey.allCases[safe: item.tag]
            item.state = a.primary.key == key ? .on : (a.sort.contains { $0.key == key } ? .mixed : .off)
            item.isHidden = key == .folder && state.location.searchQuery == nil
            return key != .dateLastOpened && key != .tags && key != .manual
        case #selector(groupBy(_:)):
            item.state = (item.tag < 0 ? a.groupBy == nil : a.groupBy == GroupKey.allCases[safe: item.tag]) ? .on : .off
        case #selector(filterByKind(_:)):
            let id = item.representedObject as? String
            item.state = id == nil ? (a.kindFilter.isEmpty ? .on : .off) : (a.kindFilter.contains(id!) ? .on : .off)
        case #selector(toggleFoldersFirst(_:)): item.state = a.foldersFirst ? .on : .off
        case #selector(toggleHiddenFiles(_:)): item.state = a.showHidden ? .on : .off
        case #selector(toggleRelativeDates(_:)): item.state = state.settings.presentation.list.relativeDates ? .on : .off
        case #selector(toggleRememberSettings(_:)):
            item.state = state.isPinned ? .on : .off
            return state.details.folderKey != nil
        default: break
        }
        return true
    }
}

// MARK: - Quick Look

extension BrowserViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !state.selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // Quartz declares these nonisolated; AppKit calls them on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewPanel = panel
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { previewPanel = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { state.selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        state.selectedItems[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item.previewItemURL, let match = state.selectedItems.first(where: { $0.url == url }) else { return .zero }
        return content?.screenFrame(for: match.id) ?? .zero
    }

    /// Arrow keys in the panel move the selection in the browser, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let content else { return false }
        content.firstResponderView.keyDown(with: event)
        return true
    }
}

/// Go menu standard locations (tags used by menu items).
enum StandardLocation: Int, CaseIterable {
    case computer = 1, home, desktop, documents, downloads, applications, utilities

    var url: URL? {
        let fm = FileManager.default
        switch self {
        case .computer: return nil
        case .home: return fm.homeDirectoryForCurrentUser
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents: return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .applications: return URL(fileURLWithPath: "/Applications")
        case .utilities: return URL(fileURLWithPath: "/Applications/Utilities")
        }
    }
}

/// Text field for the inline address bar: Return commits, Esc cancels, Tab completes.
final class AddressField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?(stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete(textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !isHidden { onCancel?() }
    }

    /// Completes the last path component to the longest common prefix of matching subfolders.
    private func complete(_ textView: NSTextView) {
        let text = stringValue
        let expanded = (text as NSString).expandingTildeInPath
        let parent = expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let partial = expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent
        Task {
            let items = (try? await DirectoryLoader.shared.loadAll(URL(fileURLWithPath: parent))) ?? []
            let matches = items.filter { $0.isNavigableFolder && $0.name.lowercased().hasPrefix(partial.lowercased()) }
                .map(\.name).sorted()
            guard let first = matches.first else { return NSSound.beep() }
            var common = first
            for m in matches.dropFirst() {
                while !m.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
            }
            var completed = (parent as NSString).appendingPathComponent(common)
            if matches.count == 1 { completed += "/" }
            if text.hasPrefix("~") { completed = (completed as NSString).abbreviatingWithTildeInPath }
            stringValue = completed
            textView.moveToEndOfDocument(nil)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
