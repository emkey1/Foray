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
    var content: ContentView?
    /// In-place rename field, laid over the item's name.
    let renameField = RenameField()
    private var renaming: FileItem?
    private var contentMode: ViewMode?
    /// Content views are kept per mode once created, so switching back reuses their rows and cells.
    private var contentCache: [ViewMode: ContentView] = [:]
    /// What each content view last rendered; a view that's already current isn't re-applied.
    private var rendered: [ViewMode: (generation: Int, settings: ViewSettings)] = [:]

    /// Forces content views to redraw (e.g. cut items dim).
    func invalidateRenderedContent() {
        rendered = [:]
        applyContentIfNeeded()
        restoreSelection()
    }
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
            applyContentIfNeeded()
            restoreSelection()
            updateStatus()
        case .snapshot:
            applyContentIfNeeded()
            prewarmOtherMode()
            restoreSelection()
            updateStatus()
            updateMessage()
            previewPanel?.reloadData()
        case .loadState:
            updateMessage()
            updateStatus()
            prewarmOtherMode()
        case .details, .location:
            updatePathBar()
            updateStatus()
            updateScopeBar()
        case .selection:
            updateStatus()
            previewPanel?.reloadData()
        case .children(let id):
            content?.childrenChanged(id)
            if contentMode != .list { rendered[.list] = nil }  // the hidden list must rebuild
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

    private func applyContentIfNeeded() {
        guard let content, let mode = contentMode else { return }
        // Generations only increase per tab, so a match means this view already shows this snapshot.
        if let last = rendered[mode], last.generation == state.snapshot.generation, last.settings == state.settings { return }
        content.apply(state.snapshot, settings: state.settings)
        rendered[mode] = (state.snapshot.generation, state.settings)
    }

    private func refreshAll() {
        updateScopeBar()
        applyContentIfNeeded()
        restoreSelection()
        updatePathBar()
        updateStatus()
        updateMessage()
    }

    /// Swaps the content view when the mode changes. Same snapshot, same selection (§3.3 rule 1–2).
    private func installContent() {
        let mode = state.settings.presentation.mode
        guard mode != contentMode else { return }
        let hadFocus = view.window?.firstResponder === content?.firstResponderView
        content?.view.isHidden = true

        let new = contentView(for: mode)
        new.view.isHidden = false
        content = new
        contentMode = mode
        sizeSlider.isHidden = mode != .icon
        sizeSlider.doubleValue = state.settings.presentation.icon.iconSize
        if hadFocus || view.window != nil { view.window?.makeFirstResponder(new.firstResponderView) }
    }

    /// The cached content view for a mode, created (hidden) if needed.
    private func contentView(for mode: ViewMode) -> ContentView {
        if let cached = contentCache[mode] { return cached }
        let new: ContentView = switch mode {
        case .icon: IconContentViewController()
        case .column: ColumnContentViewController()
        case .gallery: GalleryContentViewController()
        case .list: ListContentViewController()
        }
        new.host = self
        addChild(new)
        new.view.translatesAutoresizingMaskIntoConstraints = false
        new.view.isHidden = true
        contentContainer.addSubview(new.view)
        NSLayoutConstraint.activate([
            new.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            new.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            new.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            new.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        contentCache[mode] = new
        return new
    }

    private var prewarmWork: DispatchWorkItem?

    /// Once a folder's listing has been quiet for 300 ms, quietly builds (or refreshes) and lays out
    /// the other view (icon or list), so switching to it is a swap rather than a rebuild plus a
    /// ~110 ms first layout (DESIGN.md §5.13).
    private func prewarmOtherMode() {
        prewarmWork?.cancel()
        guard let current = contentMode, state.loadState == .complete else { return }
        let other: ViewMode = current == .icon ? .list : .icon
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.contentMode == current, self.state.loadState == .complete else { return }
                if let last = self.rendered[other], last.generation == self.state.snapshot.generation,
                   last.settings == self.state.settings { return }
                let view = self.contentView(for: other)
                view.apply(self.state.snapshot, settings: self.state.settings)
                self.rendered[other] = (self.state.snapshot.generation, self.state.settings)
                // Tables only create row views while visible, so lay it out fully transparent
                // (never seen), then hide it again.
                view.view.alphaValue = 0
                view.view.isHidden = false
                view.view.layoutSubtreeIfNeeded()
                view.view.displayIfNeeded()
                view.view.isHidden = true
                view.view.alphaValue = 1
            }
        }
        prewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
        if let free = state.availableCapacity { parts.append("\(Formatting.size(free)) available") }
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
        open(ids.compactMap(state.item), inNewTab: inNewTab)
    }

    func contentMenu(clicked: FileID?) -> NSMenu? {
        let menu = NSMenu()
        let items = state.selectedItems
        if items.isEmpty {
            menu.addItem(withTitle: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
            menu.addItem(.separator())
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
        menu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        if items.count == 1 { menu.addItem(withTitle: "Rename", action: #selector(renameSelection(_:)), keyEquivalent: "") }
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicate(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(tagsMenuItem())
        if operationFolder != nil && items.count > 1 {
            menu.addItem(withTitle: "New Folder with Selection", action: #selector(newFolderWithSelection(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quick Look", action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        if items.allSatisfy(\.isNavigableFolder) {
            menu.addItem(withTitle: "Add to Sidebar", action: #selector(addToSidebar(_:)), keyEquivalent: "")
        }
        return menu
    }

    func contentToggleQuickLook() { toggleQuickLook(nil) }

    func contentTypeSelect(_ characters: String) {
        guard let id = typeSelect.add(characters, in: state.snapshot) else { return }  // icon view: top level only
        state.setSelection([id], anchor: id)
        content?.showSelection([id], reveal: id)
    }

    func contentHeaderClicked(_ key: SortKey, shift: Bool) {
        state.updateArrangement { shift ? $0.toggleSecondary(key) : $0.setPrimary(key) }
    }

    func contentPresentationChanged(_ change: (inout Presentation) -> Void) {
        state.updatePresentation(change)
    }

    func contentRename() { renameSelection(nil) }

    // MARK: Rename in place

    func beginRename(_ item: FileItem) {
        guard state.location != .computer, let content, let frame = content.nameFrameInWindow(for: item.id) else { return }
        endRename(commit: false)
        renaming = item
        var rect = view.convert(frame, from: nil).insetBy(dx: -3, dy: -2)
        rect.size.width = max(rect.width, 160)
        rect.origin.x = max(view.bounds.minX + 2, min(rect.origin.x, view.bounds.maxX - rect.width - 2))
        renameField.frame = rect
        renameField.stringValue = item.name
        renameField.onCommit = { [weak self] in self?.endRename(commit: true) }
        renameField.onCancel = { [weak self] in self?.endRename(commit: false) }
        if renameField.superview == nil { view.addSubview(renameField) }
        renameField.isHidden = false
        view.window?.makeFirstResponder(renameField)
        // Select the name without its extension, like Finder.
        let base = FileNaming.split(item.name).base
        renameField.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }

    func endRename(commit: Bool) {
        guard let item = renaming else { return }
        renaming = nil
        let newName = renameField.stringValue
        renameField.isHidden = true
        if let content { view.window?.makeFirstResponder(content.firstResponderView) }
        guard commit, newName != item.name else { return }
        if let problem = FileNaming.problem(with: newName) {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "“\(newName)” can't be used."
            alert.informativeText = problem
            if let window = view.window { alert.beginSheetModal(for: window) }
            return
        }
        let oldExt = FileNaming.split(item.name).ext, newExt = FileNaming.split(newName).ext
        if !item.isNavigableFolder, oldExt != nil, oldExt?.lowercased() != newExt?.lowercased(), let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to change the extension from “.\(oldExt!)” to “\(newExt.map { "." + $0 } ?? "nothing")”?"
            alert.informativeText = "If you make this change, your document may open in a different app."
            alert.addButton(withTitle: "Keep .\(oldExt!)")
            alert.addButton(withTitle: newExt.map { "Use .\($0)" } ?? "Remove")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                let name = response == .alertFirstButtonReturn ? FileNaming.split(newName).base + "." + oldExt! : newName
                FileOperationsUI.shared.submit(.rename(item.url, to: name), from: self.state)
            }
            return
        }
        FileOperationsUI.shared.submit(.rename(item.url, to: newName), from: state)
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

    /// ⌃⌘T: the selected folders, or the current folder when nothing is selected.
    @objc func addToSidebar(_ sender: Any?) {
        let folders = state.selectedItems.filter(\.isNavigableFolder).map(\.url)
        if !folders.isEmpty {
            AppModel.shared.addFavorites(folders)
        } else if let url = state.location.folderURL {
            AppModel.shared.addFavorites([url])
        }
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
        guard let mode = ViewMode.allCases[safe: tag] else { return }
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
        if let answer = validateFileCommand(item) { return answer }
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
            return true
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

/// The in-place rename field: Return commits, Esc cancels, clicking elsewhere commits (like Finder).
final class RenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        isBezeled = true
        bezelStyle = .squareBezel
        focusRingType = .exterior
        font = .systemFont(ofSize: NSFont.systemFontSize)
        lineBreakMode = .byTruncatingMiddle
        cell?.isScrollable = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !isHidden { onCommit?() }
    }
}
