import AppKit
import Quartz
import RFFileSystem
import RFModel

/// Column view (DESIGN.md §5.5). The tab's location is the folder of the focused (last full)
/// column; earlier columns show its ancestors back to where column browsing started. A single
/// selected folder is "peeked" in an extra column; a single selected file gets a preview column.
/// Every column uses the tab's one Arrangement, so the order matches the other views (§3.3 rule 6).
@MainActor
final class ColumnContentViewController: NSViewController, ContentView {
    weak var host: ContentHost?

    /// One folder's arranged contents, loaded and watched while its column is on screen.
    private final class Listing {
        let url: URL
        var raw: [FileItem] = []
        var items: [FileItem] = []
        var task: Task<Void, Never>?
        init(url: URL) { self.url = url }
    }

    private let scrollView = NSScrollView()
    /// Columns are laid out by hand (fixed widths, full visible height). Constraining them to the
    /// scroll view's clip view made the window shrink to fit (532 → 76 points in a test).
    private let document = FlippedView()
    private var columns: [ColumnTable] = []
    private let preview = PreviewColumn()
    /// Where column browsing started; columns run from here to the current location.
    private var root: URL?
    private var listings: [URL: Listing] = [:]
    private var snapshot = ItemSnapshot.empty
    private var settings = ViewSettings()
    private var isApplying = false
    /// The last current column's folder and items, to seed that folder's listing when it becomes
    /// an ancestor or peek column (so it doesn't flash empty while reloading).
    private var lastCurrent: (url: URL, items: [FileItem])?

    var firstResponderView: NSView { columns.last(where: { $0.role == .current })?.table ?? view }

    override func loadView() {
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns()
    }

    /// Columns, then the preview column if shown, side by side at full visible height.
    private func layoutColumns() {
        let height = scrollView.contentSize.height
        var x: CGFloat = 0
        let arranged: [NSView] = columns + (preview.superview != nil ? [preview] : [])
        for v in arranged {
            let width: CGFloat = v === preview ? 320 : settings.presentation.column.columnWidth
            v.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        document.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.contentSize.width), height: height)
    }

    /// For tests: each column's role, folder name and item names; and whether a preview shows.
    var columnSummaries: [(role: String, folder: String, items: [String])] {
        columns.map { ("\($0.role)", $0.folder?.lastPathComponent ?? "", $0.itemNames) }
    }
    var isShowingPreview: Bool { preview.superview != nil }

    // MARK: ContentView

    func apply(_ snapshot: ItemSnapshot, settings: ViewSettings) {
        isApplying = true
        defer { isApplying = false }
        let arrangementChanged = settings.arrangement != self.settings.arrangement
        self.snapshot = snapshot
        self.settings = settings
        if arrangementChanged { for l in listings.values { arrange(l) } }
        rebuild()
    }

    func showSelection(_ ids: Set<FileID>, reveal: FileID?) {
        isApplying = true
        defer { isApplying = false }
        guard let current = columns.last(where: { $0.role == .current }) else { return }
        current.select(ids: ids, reveal: reveal)
        updatePeekAndPreview()
    }

    func screenFrame(for id: FileID) -> NSRect? {
        guard let current = columns.last(where: { $0.role == .current }), let rect = current.iconFrameInWindow(id: id),
              let window = view.window else { return nil }
        return window.convertToScreen(rect)
    }

    func nameFrameInWindow(for id: FileID) -> NSRect? {
        columns.last(where: { $0.role == .current })?.nameFrameInWindow(id: id)
    }

    // MARK: Building the columns

    /// Folders from the root down to the current location.
    private func chain() -> [URL] {
        guard let current = host?.state.location.folderURL?.standardizedFileURL else { return [] }
        if let r = root?.standardizedFileURL, current.path == r.path || current.path.hasPrefix(r.path == "/" ? "/" : r.path + "/") {
            var urls: [URL] = []
            var u = current
            while true {
                urls.insert(u, at: 0)
                if u.path == r.path || u.path == "/" { break }
                u = u.deletingLastPathComponent().standardizedFileURL
            }
            return urls
        }
        root = current
        return [current]
    }

    private func rebuild() {
        let state = host?.state
        let path = chain()
        let currentItems = snapshot.items  // groups don't apply in column view
        var specs: [(ColumnTable.Role, URL?, [FileItem], FileID?)] = []
        if path.isEmpty {
            // Search results, Computer: one column with the snapshot.
            specs.append((.current, nil, currentItems, nil))
        } else {
            for (i, url) in path.enumerated() {
                if i == path.count - 1 {
                    specs.append((.current, url, currentItems, nil))
                } else {
                    let listing = listing(for: url)
                    let next = path[i + 1].standardizedFileURL.path
                    let highlight = listing.items.first { $0.url.standardizedFileURL.path == next }?.id
                    specs.append((.ancestor, url, listing.items, highlight))
                }
            }
        }
        // Reuse column views where possible.
        while columns.count < specs.count {
            let c = ColumnTable(width: settings.presentation.column.columnWidth)
            c.owner = self
            columns.append(c)
            document.addSubview(c)
        }
        while columns.count > specs.count { columns.removeLast().removeFromSuperview() }
        for (column, spec) in zip(columns, specs) {
            column.configure(role: spec.0, folder: spec.1, items: spec.2, highlighted: spec.3,
                             showIcons: true, relative: settings.presentation.list.relativeDates)
        }
        if let state, let current = columns.last { current.select(ids: state.selection, reveal: state.focusAnchor) }
        if let url = path.last, !currentItems.isEmpty { lastCurrent = (url.standardizedFileURL, currentItems) }
        // Drop listings no longer needed (the peek column re-adds its own).
        let needed = Set(path.dropLast().map(\.standardizedFileURL.path))
        for (key, l) in listings where !needed.contains(key.standardizedFileURL.path) {
            l.task?.cancel()
            listings[key] = nil
        }
        updatePeekAndPreview()
    }

    /// A single selected folder shows its contents in a peek column; a single file, a preview.
    private func updatePeekAndPreview() {
        columns.removeAll { c in
            if c.role == .peek { c.removeFromSuperview(); return true }
            return false
        }
        preview.removeFromSuperview()
        guard let state = host?.state, state.selection.count == 1, let item = state.selectedItems.first else {
            scrollToEnd()
            return
        }
        if item.isNavigableFolder {
            let listing = listing(for: item.url)
            let peek = ColumnTable(width: settings.presentation.column.columnWidth)
            peek.owner = self
            peek.configure(role: .peek, folder: item.url, items: listing.items, highlighted: nil, showIcons: true,
                           relative: settings.presentation.list.relativeDates)
            columns.append(peek)
            document.addSubview(peek)
        } else if settings.presentation.column.showPreviewColumn {
            document.addSubview(preview)   // in the window first: QLPreviewView asserts otherwise
            preview.show(item)
        }
        scrollToEnd()
    }

    private func scrollToEnd() {
        layoutColumns()
        guard let doc = scrollView.documentView else { return }
        let x = max(0, doc.frame.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Listings for ancestor and peek columns

    private func listing(for url: URL) -> Listing {
        let key = url.standardizedFileURL
        if let l = listings[key] { return l }
        let l = Listing(url: key)
        listings[key] = l
        if let seed = lastCurrent, seed.url.path == key.path {
            l.raw = seed.items
            l.items = seed.items
        }
        l.task = Task { [weak self, weak l] in
            for await event in FolderContents.observe(key) {
                guard let self, let l, !Task.isCancelled else { break }
                switch event {
                case .partial: continue
                case .complete(let items): l.raw = items
                case .failed: l.raw = []
                }
                self.arrange(l)
                self.refreshColumns(showing: key)
            }
        }
        return l
    }

    private func arrange(_ l: Listing) {
        var a = settings.arrangement
        a.groupBy = nil
        l.items = ArrangementEngine.arrange(l.raw, with: a).items
    }

    private func refreshColumns(showing url: URL) {
        for c in columns where c.folder?.standardizedFileURL.path == url.path && c.role != .current {
            let items = listings[url]?.items ?? []
            var highlight: FileID?
            if c.role == .ancestor, let i = columns.firstIndex(where: { $0 === c }), i + 1 < columns.count,
               let next = columns[i + 1].folder?.standardizedFileURL.path {
                highlight = items.first { $0.url.standardizedFileURL.path == next }?.id
            }
            c.configure(role: c.role, folder: c.folder, items: items, highlighted: highlight, showIcons: true,
                        relative: settings.presentation.list.relativeDates)
        }
    }

    // MARK: Events from columns

    fileprivate func selectionChanged(in column: ColumnTable, ids: Set<FileID>) {
        guard !isApplying, let state = host?.state else { return }
        switch column.role {
        case .current:
            host?.contentSelectionChanged(ids, anchor: ids.first)
            updatePeekAndPreview()
        case .ancestor, .peek:
            // Clicking in another column moves focus there: that folder becomes the location.
            guard let folder = column.folder, let id = ids.first, let item = column.item(id) else { return }
            state.navigate(to: .folder(folder), select: [item.name])
        }
    }

    fileprivate func open(_ item: FileItem, newTab: Bool) {
        host?.contentOpen([item.id], inNewTab: newTab)
    }

    /// Keyboard → and ← on the focused column (also used by tests).
    func moveRightFromCurrent() { if let c = columns.last(where: { $0.role == .current }) { moveRight(from: c) } }
    func moveLeftFromCurrent() { if let c = columns.last(where: { $0.role == .current }) { moveLeft(from: c) } }

    /// → : into the selected folder (selecting its first item). ← : back to the parent column.
    fileprivate func moveRight(from column: ColumnTable) {
        guard column.role == .current, let state = host?.state, state.selection.count == 1,
              let folder = state.selectedItems.first, folder.isNavigableFolder else { return }
        let first = listings[folder.url.standardizedFileURL]?.items.first?.name
        state.navigate(to: .folder(folder.url), select: first.map { [$0] } ?? [])
    }

    fileprivate func moveLeft(from column: ColumnTable) {
        guard let state = host?.state, let current = state.location.folderURL, current.path != "/" else { return }
        if root?.standardizedFileURL.path == current.standardizedFileURL.path { root = current.deletingLastPathComponent() }
        state.navigate(to: .folder(current.deletingLastPathComponent()), select: [current.lastPathComponent])
    }

    fileprivate func menu(for column: ColumnTable, clicked: FileID?) -> NSMenu? {
        column.role == .current ? host?.contentMenu(clicked: clicked) : nil
    }
}

/// A document view with a top-left origin, so columns hang from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One column: a single-column table in its own vertical scroll view, with a separator.
@MainActor
private final class ColumnTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Role { case ancestor, current, peek }

    weak var owner: ColumnContentViewController?
    private(set) var role: Role = .current
    private(set) var folder: URL?
    private var items: [FileItem] = []
    private var highlighted: FileID?
    private var relativeDates = true
    let table = ColumnTableView()
    private let scroll = NSScrollView()
    private var suppress = false

    init(width: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .fullWidth
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.column = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let separator = NSBox()
        separator.boxType = .separator
        for v in [scroll, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func item(_ id: FileID) -> FileItem? { items.first { $0.id == id } }
    var itemNames: [String] { items.map(\.name) }

    func configure(role: Role, folder: URL?, items: [FileItem], highlighted: FileID?, showIcons: Bool, relative: Bool) {
        let changed = self.items.map(\.id) != items.map(\.id) || self.items != items
        self.role = role
        self.folder = folder
        self.items = items
        self.highlighted = highlighted
        relativeDates = relative
        suppress = true
        defer { suppress = false }
        if changed { table.reloadData() }
        if role != .current {
            let row = highlighted.flatMap { id in items.firstIndex { $0.id == id } }
            table.selectRowIndexes(row.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
            if let row { table.scrollRowToVisible(row) }
        }
        alphaValue = role == .peek ? 0.85 : 1
    }

    func select(ids: Set<FileID>, reveal: FileID?) {
        suppress = true
        defer { suppress = false }
        var rows = IndexSet()
        for (i, item) in items.enumerated() where ids.contains(item.id) { rows.insert(i) }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let reveal, let i = items.firstIndex(where: { $0.id == reveal }) { table.scrollRowToVisible(i) }
    }

    func iconFrameInWindow(id: FileID) -> NSRect? {
        guard let row = items.firstIndex(where: { $0.id == id }) else { return nil }
        let rect = table.rect(ofRow: row)
        return table.convert(NSRect(x: rect.minX + 4, y: rect.minY, width: rect.height, height: rect.height), to: nil)
    }

    func nameFrameInWindow(id: FileID) -> NSRect? {
        guard let row = items.firstIndex(where: { $0.id == id }) else { return nil }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCell else { return nil }
        return cell.label.convert(cell.label.bounds, to: nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("col"), owner: self) as? ColumnCell ?? ColumnCell()
        cell.configure(items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress else { return }
        let ids = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].id : nil })
        owner?.selectionChanged(in: self, ids: ids)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items[row].displayName
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < items.count else { return }
        owner?.open(items[table.clickedRow], newTab: NSEvent.modifierFlags.contains(.command))
    }

    fileprivate func keyDown(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.keyCode {
        case 124 where plain: owner?.moveRight(from: self); return true          // →
        case 123 where plain: owner?.moveLeft(from: self); return true           // ←
        case 36 where plain && role == .current, 76 where plain && role == .current:   // Return / Enter
            owner?.host?.contentRename()
            return true
        case 49 where plain: owner?.host?.contentToggleQuickLook(); return true  // Space
        default: return false
        }
    }

    fileprivate func menu(at row: Int) -> NSMenu? {
        if row >= 0, role == .current, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return owner?.menu(for: self, clicked: row >= 0 && row < items.count ? items[row].id : nil)
    }
}

@MainActor
private final class ColumnTableView: NSTableView {
    weak var column: ColumnTable?

    override func keyDown(with event: NSEvent) {
        if column?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        column?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// Icon, name and (for folders) a chevron. Manual layout, like the list cells.
private final class ColumnCell: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
    private let dots = TagDotsView()
    private var itemID: FileID?

    init() {
        super.init(frame: .zero)
        identifier = .init("col")
        label.lineBreakMode = .byTruncatingMiddle
        icon.imageScaling = .scaleProportionallyUpOrDown
        chevron.contentTintColor = .tertiaryLabelColor
        for v in [icon, label, chevron, dots] as [NSView] { addSubview(v) }
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 6, y: (h - 16) / 2, width: 16, height: 16)
        chevron.frame = NSRect(x: bounds.width - 16, y: (h - 10) / 2, width: 8, height: 10)
        let th = label.intrinsicContentSize.height
        let trailing: CGFloat = chevron.isHidden ? 6 : 22
        let dotsWidth = dots.isHidden ? 0 : dots.dotsWidth + 6
        label.frame = NSRect(x: 28, y: (h - th) / 2, width: max(0, bounds.width - 28 - trailing - dotsWidth), height: th)
        dots.frame = NSRect(x: bounds.width - trailing - dotsWidth + 2, y: (h - TagDotsView.diameter) / 2,
                            width: dots.dotsWidth, height: TagDotsView.diameter)
    }

    func configure(_ item: FileItem) {
        itemID = item.id
        label.stringValue = item.displayName
        icon.image = IconProvider.shared.icon(for: item)
        chevron.isHidden = !item.isNavigableFolder
        alphaValue = item.flags.contains(.hidden) || FileClipboard.isCut(item.url) ? 0.5 : 1
        IconProvider.shared.loadFileIcon(for: item) { [weak self] image in
            guard self?.itemID == item.id else { return }
            self?.icon.image = image
        }
        dots.tags = TagProvider.shared.cached(item) ?? []
        TagProvider.shared.load(item) { [weak self] tags in
            guard let self, self.itemID == item.id, self.dots.tags != tags else { return }
            self.dots.tags = tags
            self.needsLayout = true
        }
        needsLayout = true
    }
}

/// Preview of a selected file at the end of the columns: Quick Look plus basic facts.
@MainActor
private final class PreviewColumn: NSView {
    private let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), style: .compact)!
    private let name = NSTextField(wrappingLabelWithString: "")
    private let facts = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.alignment = .center
        facts.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        facts.textColor = .secondaryLabelColor
        for v in [preview, name, facts] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor),
            name.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            facts.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            facts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            facts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var pendingItem: NSURL?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let pending = pendingItem {
            pendingItem = nil
            preview.previewItem = pending
        }
    }

    func show(_ item: FileItem) {
        // Never trigger a download for a file that's only in the cloud.
        let url: NSURL? = item.flags.contains(.dataless) ? nil : item.url as NSURL
        if window != nil {
            preview.previewItem = url
        } else {
            pendingItem = url   // QLPreviewView asserts if given an item before it's in a window
        }
        name.stringValue = item.displayName
        var lines = ["\(KindNames.name(for: item)) — \(Formatting.size(for: item))"]
        lines.append("Created  \(Formatting.date(item.created, relative: false))")
        lines.append("Modified  \(Formatting.date(item.modified, relative: false))")
        if let added = item.added { lines.append("Added  \(Formatting.date(added, relative: false))") }
        facts.stringValue = lines.joined(separator: "\n")
    }
}
