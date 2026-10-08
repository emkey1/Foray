import AppKit
import RFModel

/// List view (DESIGN.md §5.5): an outline whose folders expand in place. Column headers edit the
/// shared Arrangement; the sort chip shows a sort key that has no visible column (rule 5, §3.3).
/// Expanded folders live in BrowserState (loaded, watched and arranged there).
@MainActor
final class ListContentViewController: NSViewController, ContentView {
    weak var host: ContentHost?

    /// Outline rows need stable object identity across reloads, so nodes are cached by FileID.
    final class Node {
        enum Kind {
            case group(String)
            case item(FileItem)
        }
        var kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        var item: FileItem? { if case .item(let i) = kind { i } else { nil } }
    }

    private let outline = BrowserOutlineView()
    private let scrollView = NSScrollView()
    private let chip = NSTextField(labelWithString: "")
    private let chipButton = NSButton(title: "Show Column", target: nil, action: nil)
    private let chipBar = NSStackView()
    private var chipBarHeight: NSLayoutConstraint?
    private var snapshot = ItemSnapshot.empty
    private var settings = ViewSettings()
    /// Top-level rows. Item nodes are created on demand (outline views ask only for rows they
    /// need), so a 100k-item list doesn't allocate 100k objects up front.
    private enum Entry {
        case group(Node)
        case item(Int)   // index into snapshot.items
    }
    private var topLevel: [Entry] = []
    private var nodes: [FileID: Node] = [:]
    private var groupNodes: [String: Node] = [:]
    private var isApplying = false

    var firstResponderView: NSView { outline }

    override func loadView() {
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 6, height: 2)
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.owner = self
        outline.headerView?.menu = headerMenu()
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move, .generic, .link, .delete], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        chip.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        chip.textColor = .secondaryLabelColor
        chipButton.bezelStyle = .inline
        chipButton.controlSize = .small
        chipButton.target = self
        chipButton.action = #selector(showSortColumn)
        chipBar.orientation = .horizontal
        chipBar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        chipBar.addArrangedSubview(chip)
        chipBar.addArrangedSubview(chipButton)
        chipBar.addArrangedSubview(NSView())
        chipBar.isHidden = true

        // Plain container with explicit constraints: an NSStackView root shrinks to its fitting
        // size, which is zero height for a scroll view.
        let root = NSView()
        for v in [chipBar, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        chipBarHeight = chipBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: root.topAnchor),
            chipBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chipBarHeight!,
            scrollView.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged), name: NSTableView.columnDidResizeNotification, object: outline)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged), name: NSTableView.columnDidMoveNotification, object: outline)
    }

    // MARK: ContentView

    func apply(_ snapshot: ItemSnapshot, settings: ViewSettings) {
        isApplying = true
        defer { isApplying = false }
        let columnsChanged = settings.presentation.list.columns != self.settings.presentation.list.columns || outline.tableColumns.isEmpty
        self.snapshot = snapshot
        self.settings = settings
        if columnsChanged { rebuildColumns() }
        rebuildTopLevel()
        outline.reloadData()
        restoreExpansion(in: (host?.state.expanded ?? []).compactMap { id in
            snapshot.index(of: id).map { node(for: snapshot.items[$0]) }
        })
        updateSortIndicators()
        updateChip()
    }

    /// An expanded folder's contents arrived or changed.
    func childrenChanged(_ id: FileID) {
        guard let parent = nodes[id] else { return }
        isApplying = true
        defer { isApplying = false }
        for child in host?.state.children[id]?.items ?? [] { _ = node(for: child) }
        outline.reloadItem(parent, reloadChildren: true)
        if host?.state.expanded.contains(id) == true && !outline.isItemExpanded(parent) { outline.expandItem(parent) }
        let kids = (host?.state.children[id]?.items ?? []).compactMap { nodes[$0.id] }
        restoreExpansion(in: kids)
        if let state = host?.state { showSelection(state.selection, reveal: nil) }
    }

    func showSelection(_ ids: Set<FileID>, reveal: FileID?) {
        isApplying = true
        defer { isApplying = false }
        var rows = IndexSet()
        for id in ids {
            if let node = existingOrTopLevelNode(id) {
                let row = outline.row(forItem: node)
                if row >= 0 { rows.insert(row) }
            }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let reveal, let node = existingOrTopLevelNode(reveal) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
    }

    func screenFrame(for id: FileID) -> NSRect? {
        guard let node = existingOrTopLevelNode(id), let window = view.window,
              let column = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == ListColumn.name.rawValue })
        else { return nil }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return nil }
        let rect = outline.frameOfCell(atColumn: column, row: row)
        let iconRect = NSRect(x: rect.minX + 2, y: rect.minY, width: rect.height, height: rect.height)
        return window.convertToScreen(outline.convert(iconRect, to: nil))
    }

    func nameFrameInWindow(for id: FileID) -> NSRect? {
        guard let node = existingOrTopLevelNode(id),
              let column = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == ListColumn.name.rawValue })
        else { return nil }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return nil }
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let text = cell.textField else { return nil }
        return text.convert(text.bounds, to: nil)
    }

    // MARK: Building

    /// The node for an item that's shown: cached, or created for a top-level item.
    private func existingOrTopLevelNode(_ id: FileID) -> Node? {
        if let n = nodes[id] { return n }
        return snapshot.index(of: id).map { node(for: snapshot.items[$0]) }
    }

    private func node(for item: FileItem) -> Node {
        if let existing = nodes[item.id] {
            existing.kind = .item(item)
            return existing
        }
        let new = Node(.item(item))
        nodes[item.id] = new
        return new
    }

    private func rebuildTopLevel() {
        topLevel = []
        topLevel.reserveCapacity(snapshot.items.count + snapshot.groups.count)
        for node in nodes.values {
            // Keep cached nodes' items current (renames, size changes) without allocating new ones.
            if let id = node.item?.id, let i = snapshot.index(of: id) { node.kind = .item(snapshot.items[i]) }
        }
        if snapshot.groups.isEmpty {
            for i in snapshot.items.indices { topLevel.append(.item(i)) }
        } else {
            for group in snapshot.groups {
                let g = groupNodes[group.title] ?? Node(.group(group.title))
                groupNodes[group.title] = g
                topLevel.append(.group(g))
                for i in group.range { topLevel.append(.item(i)) }
            }
        }
        // Drop nodes for items no longer shown anywhere (keeps the cache bounded).
        if nodes.count > snapshot.items.count * 2 + 1_000, let state = host?.state {
            nodes = nodes.filter { state.item($0.key) != nil }
        }
    }

    /// Re-expands rows the tab has expanded (reloadData collapses everything).
    private func restoreExpansion(in candidates: [Node]) {
        guard let state = host?.state, !state.expanded.isEmpty else { return }
        for node in candidates {
            guard let item = node.item, state.expanded.contains(item.id) else { continue }
            for child in state.children[item.id]?.items ?? [] { _ = self.node(for: child) }
            outline.expandItem(node)
        }
    }

    private func rebuildColumns() {
        for c in outline.tableColumns { outline.removeTableColumn(c) }
        for spec in settings.presentation.list.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.column.rawValue))
            column.title = spec.column.title
            column.width = spec.width
            column.minWidth = spec.column == .name ? 120 : 50
            if spec.column == .size { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if spec.column == .name { outline.outlineTableColumn = column }
        }
    }

    private func updateSortIndicators() {
        let primary = settings.arrangement.primary
        for column in outline.tableColumns {
            let key = ListColumn(rawValue: column.identifier.rawValue)?.sortKey
            let image = key == primary.key
                ? NSImage(named: primary.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
            outline.setIndicatorImage(image, in: column)
            if key == primary.key { outline.highlightedTableColumn = column }
        }
        let secondary = settings.arrangement.sort.dropFirst().map { "\($0.key.title) \($0.ascending ? "↑" : "↓")" }
        outline.headerView?.toolTip = secondary.isEmpty ? nil : "Then by " + secondary.joined(separator: ", ")
    }

    /// Rule 5: never silently switch to another column when the sort key isn't visible.
    private func updateChip() {
        let primary = settings.arrangement.primary
        let hidden = primary.key != .manual && !settings.presentation.list.isVisible(primary.key)
        chipBar.isHidden = !hidden
        chipBarHeight?.constant = hidden ? 24 : 0
        chip.stringValue = "Sorted by \(primary.key.title) \(primary.ascending ? "↑" : "↓")"
        chipButton.isHidden = ListColumn.allCases.first { $0.sortKey == primary.key } == nil
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0, let item = (outline.item(atRow: outline.clickedRow) as? Node)?.item else { return }
        host?.contentOpen([item.id], inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    @objc private func showSortColumn() {
        guard let column = ListColumn.allCases.first(where: { $0.sortKey == settings.arrangement.primary.key }) else { return }
        host?.contentPresentationChanged { $0.list.columns.append(ListColumnSpec(column)) }
    }

    @objc private func columnsChanged() {
        guard !isApplying else { return }
        let specs = outline.tableColumns.compactMap { c -> ListColumnSpec? in
            guard let column = ListColumn(rawValue: c.identifier.rawValue) else { return nil }
            return ListColumnSpec(column, width: c.width)
        }
        // Avoid rebuilding columns for our own echo.
        settings.presentation.list.columns = specs
        host?.contentPresentationChanged { $0.list.columns = specs }
    }

    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? String, let c = ListColumn(rawValue: column) else { return }
        host?.contentPresentationChanged { p in
            if let i = p.list.columns.firstIndex(where: { $0.column == c }) {
                p.list.columns.remove(at: i)
            } else {
                p.list.columns.append(ListColumnSpec(c))
            }
        }
    }

    fileprivate func ids(atRows rows: IndexSet) -> [FileID] {
        rows.compactMap { (outline.item(atRow: $0) as? Node)?.item?.id }
    }

    fileprivate func menu(forRow row: Int) -> NSMenu? {
        if row >= 0, !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let clicked = row >= 0 ? ids(atRows: IndexSet(integer: row)).first : nil
        return host?.contentMenu(clicked: clicked)
    }
}

extension ListContentViewController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return topLevel.count }
        guard let id = node.item?.id else { return 0 }
        return host?.state.children[id]?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node, let id = node.item?.id, let kids = host?.state.children[id] else {
            switch topLevel[index] {
            case .group(let g): return g
            case .item(let i): return self.node(for: snapshot.items[i])
            }
        }
        return self.node(for: kids.items[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.item?.isNavigableFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .group = (item as? Node)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.item != nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = (notification.userInfo?["NSObject"] as? Node)?.item else { return }
        host?.state.expand(item, recursive: !isApplying && NSEvent.modifierFlags.contains(.option))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplying, let item = (notification.userInfo?["NSObject"] as? Node)?.item else { return }
        host?.state.collapse(item.id)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.kind {
        case .group(let title):
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView ?? GroupCell()
            cell.textField?.stringValue = title
            return cell
        case .item(let item):
            guard let tableColumn, let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            if column == .name {
                let cell = outlineView.makeView(withIdentifier: .init("name"), owner: self) as? NameCell ?? NameCell()
                cell.configure(item)
                return cell
            }
            let cell = outlineView.makeView(withIdentifier: .init("text"), owner: self) as? TextCell ?? TextCell()
            cell.textField?.stringValue = Formatting.text(
                for: item, column: column, relativeDates: settings.presentation.list.relativeDates,
                whereBase: host?.state.location.searchQuery?.scope.folderURL)
            cell.textField?.alignment = column == .size ? .right : .left
            cell.textField?.lineBreakMode = column == .folder ? .byTruncatingHead : .byTruncatingTail
            return cell
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        let selected = ids(atRows: outline.selectedRowIndexes)
        let anchorRow = outline.selectedRow
        let anchor = anchorRow >= 0 ? ids(atRows: IndexSet(integer: anchorRow)).first : nil
        host?.contentSelectionChanged(Set(selected), anchor: anchor)
    }

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        guard let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return }
        host?.contentHeaderClicked(column.sortKey, shift: NSEvent.modifierFlags.contains(.shift))
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == ListColumn.name.rawValue else { return nil }
        return (item as? Node)?.item?.displayName
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        (item as? Node)?.item.map { $0.url as NSURL }
    }

    /// Drops onto a folder row go into that folder; anywhere else, into the folder being shown.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        if let folder = (item as? Node)?.item, folder.isNavigableFolder {
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return DragAndDrop.operation(info, to: folder.url)
        }
        guard let here = host?.state.location.folderURL else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return DragAndDrop.operation(info, to: here)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let target = (item as? Node)?.item.flatMap { $0.isNavigableFolder ? $0.url : nil } ?? host?.state.location.folderURL
        guard let target else { return false }
        return DragAndDrop.perform(info, to: target, from: host?.state)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        let urls = session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DragAndDrop.draggingEnded(operation, items: urls, state: host?.state)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in ListColumn.allCases where column != .name {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = settings.presentation.list.columns.contains { $0.column == column } ? .on : .off
            menu.addItem(item)
        }
    }
}

/// Outline subclass: Space for Quick Look, context menus via the host.
final class BrowserOutlineView: NSOutlineView {
    weak var owner: ListContentViewController?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.charactersIgnoringModifiers == " " && plain {
            owner?.host?.contentToggleQuickLook()
            return
        }
        if plain && (event.keyCode == 36 || event.keyCode == 76) {  // Return / Enter: rename, like Finder
            owner?.host?.contentRename()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return owner?.menu(forRow: row)
    }
}

/// List cells lay out by hand: a constraint solve per cell made the first draw of a list
/// noticeably slower (DESIGN.md §5.13 view-switch budget).
private final class NameCell: NSTableCellView {
    private var itemID: FileID?
    private let dots = TagDotsView()
    private let cloud = CloudBadgeView()

    init() {
        super.init(frame: .zero)
        identifier = .init("name")
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        addSubview(image)
        addSubview(text)
        addSubview(dots)
        addSubview(cloud)
        imageView = image
        textField = text
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        imageView?.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16)
        let textSize = textField?.intrinsicContentSize ?? .zero
        let dotsWidth = dots.isHidden ? 0 : dots.dotsWidth + 6
        let cloudWidth = cloud.isHidden ? 0 : CloudBadgeView.size + 6
        let available = max(0, bounds.width - 26 - dotsWidth - cloudWidth)
        let textWidth = min(textSize.width, available)
        textField?.frame = NSRect(x: 24, y: (h - textSize.height) / 2, width: textWidth, height: textSize.height)
        // Tag dots right after the name, like Finder.
        dots.frame = NSRect(x: 24 + textWidth + 4, y: (h - TagDotsView.diameter) / 2, width: dots.dotsWidth, height: TagDotsView.diameter)
        // Not downloaded: a cloud at the right edge of the name column, like Finder.
        let s = CloudBadgeView.size
        cloud.frame = NSRect(x: bounds.width - s - 4, y: (h - s) / 2, width: s, height: s)
    }

    func configure(_ item: FileItem) {
        itemID = item.id
        textField?.stringValue = item.displayName
        imageView?.image = IconProvider.shared.icon(for: item)
        alphaValue = item.flags.contains(.hidden) || FileClipboard.isCut(item.url) ? 0.5 : 1
        IconProvider.shared.loadFileIcon(for: item) { [weak self] image in
            guard self?.itemID == item.id else { return }
            self?.imageView?.image = image
        }
        cloud.show(for: item)
        dots.tags = TagProvider.shared.cached(item) ?? []
        TagProvider.shared.load(item) { [weak self] tags in
            guard let self, self.itemID == item.id, self.dots.tags != tags else { return }
            self.dots.tags = tags
            self.needsLayout = true
        }
        needsLayout = true
    }
}

private final class TextCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        identifier = .init("text")
        let text = NSTextField(labelWithString: "")
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        addSubview(text)
        textField = text
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let textHeight = textField?.intrinsicContentSize.height ?? 16
        textField?.frame = NSRect(x: 2, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - 4), height: textHeight)
    }
}

private final class GroupCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        identifier = .init("group")
        let text = NSTextField(labelWithString: "")
        text.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = text
    }

    required init?(coder: NSCoder) { fatalError() }
}
