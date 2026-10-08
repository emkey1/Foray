import AppKit
import RFModel

/// List view (DESIGN.md §5.5). Column headers edit the shared Arrangement; the sort chip shows a
/// sort key that has no visible column (rule 5, §3.3). Disclosure triangles come later in M1.
@MainActor
final class ListContentViewController: NSViewController, ContentView {
    weak var host: ContentHost?

    private enum Row {
        case group(String)
        case item(Int)
    }

    private let tableView = BrowserTableView()
    private let scrollView = NSScrollView()
    private let chip = NSTextField(labelWithString: "")
    private let chipButton = NSButton(title: "Show Column", target: nil, action: nil)
    private let chipBar = NSStackView()
    private var snapshot = ItemSnapshot.empty
    private var settings = ViewSettings()
    private var rows: [Row] = []
    private var rowForIndex: [Int] = []
    private var isApplying = false

    var firstResponderView: NSView { tableView }

    override func loadView() {
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.owner = self
        tableView.headerView?.menu = headerMenu()

        scrollView.documentView = tableView
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

        let stack = NSStackView(views: [chipBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        chipBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack

        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged), name: NSTableView.columnDidResizeNotification, object: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged), name: NSTableView.columnDidMoveNotification, object: tableView)
    }

    // MARK: ContentView

    func apply(_ snapshot: ItemSnapshot, settings: ViewSettings) {
        isApplying = true
        defer { isApplying = false }
        let columnsChanged = settings.presentation.list.columns != self.settings.presentation.list.columns || tableView.tableColumns.isEmpty
        self.snapshot = snapshot
        self.settings = settings
        if columnsChanged { rebuildColumns() }
        rebuildRows()
        tableView.reloadData()
        updateSortIndicators()
        updateChip()
    }

    func showSelection(_ ids: Set<FileID>, reveal: FileID?) {
        isApplying = true
        defer { isApplying = false }
        var rowSet = IndexSet()
        for id in ids { if let i = snapshot.index(of: id) { rowSet.insert(rowForIndex[i]) } }
        tableView.selectRowIndexes(rowSet, byExtendingSelection: false)
        if let reveal, let i = snapshot.index(of: reveal) { tableView.scrollRowToVisible(rowForIndex[i]) }
    }

    func screenFrame(for id: FileID) -> NSRect? {
        guard let i = snapshot.index(of: id), let window = view.window,
              let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == ListColumn.name.rawValue })
        else { return nil }
        let rect = tableView.frameOfCell(atColumn: column, row: rowForIndex[i])
        let iconRect = NSRect(x: rect.minX + 2, y: rect.minY, width: rect.height, height: rect.height)
        return window.convertToScreen(tableView.convert(iconRect, to: nil))
    }

    // MARK: Building

    private func rebuildColumns() {
        for c in tableView.tableColumns { tableView.removeTableColumn(c) }
        for spec in settings.presentation.list.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.column.rawValue))
            column.title = spec.column.title
            column.width = spec.width
            column.minWidth = spec.column == .name ? 120 : 50
            if spec.column == .size { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
    }

    private func rebuildRows() {
        rows = []
        rowForIndex = Array(repeating: 0, count: snapshot.items.count)
        if snapshot.groups.isEmpty {
            rows.reserveCapacity(snapshot.items.count)
            for i in snapshot.items.indices {
                rowForIndex[i] = rows.count
                rows.append(.item(i))
            }
        } else {
            for group in snapshot.groups {
                rows.append(.group(group.title))
                for i in group.range {
                    rowForIndex[i] = rows.count
                    rows.append(.item(i))
                }
            }
        }
    }

    private func updateSortIndicators() {
        let primary = settings.arrangement.primary
        for column in tableView.tableColumns {
            let key = ListColumn(rawValue: column.identifier.rawValue)?.sortKey
            let image = key == primary.key
                ? NSImage(named: primary.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
            tableView.setIndicatorImage(image, in: column)
            if key == primary.key { tableView.highlightedTableColumn = column }
        }
        let secondary = settings.arrangement.sort.dropFirst().map { "\($0.key.title) \($0.ascending ? "↑" : "↓")" }
        tableView.headerView?.toolTip = secondary.isEmpty ? nil : "Then by " + secondary.joined(separator: ", ")
    }

    /// Rule 5: never silently switch to another column when the sort key isn't visible.
    private func updateChip() {
        let primary = settings.arrangement.primary
        let hidden = primary.key != .manual && !settings.presentation.list.isVisible(primary.key)
        chipBar.isHidden = !hidden
        chip.stringValue = "Sorted by \(primary.key.title) \(primary.ascending ? "↑" : "↓")"
        chipButton.isHidden = ListColumn.allCases.first { $0.sortKey == primary.key } == nil
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        guard tableView.clickedRow >= 0, case .item(let i) = rows[tableView.clickedRow] else { return }
        host?.contentOpen([snapshot.items[i].id], inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    @objc private func showSortColumn() {
        guard let column = ListColumn.allCases.first(where: { $0.sortKey == settings.arrangement.primary.key }) else { return }
        host?.contentPresentationChanged { $0.list.columns.append(ListColumnSpec(column)) }
    }

    @objc private func columnsChanged() {
        guard !isApplying else { return }
        let specs = tableView.tableColumns.compactMap { c -> ListColumnSpec? in
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

    fileprivate func items(atRows rowIndexes: IndexSet) -> [FileID] {
        rowIndexes.compactMap { r in
            guard r < rows.count, case .item(let i) = rows[r] else { return nil }
            return snapshot.items[i].id
        }
    }

    fileprivate func menu(forRow row: Int) -> NSMenu? {
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let clicked = row >= 0 ? items(atRows: IndexSet(integer: row)).first : nil
        return host?.contentMenu(clicked: clicked)
    }
}

extension ListContentViewController: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let cell = tableView.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView ?? GroupCell()
            cell.textField?.stringValue = title
            return cell
        case .item(let i):
            let item = snapshot.items[i]
            guard let tableColumn, let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            if column == .name {
                let cell = tableView.makeView(withIdentifier: .init("name"), owner: self) as? NameCell ?? NameCell()
                cell.configure(item)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: .init("text"), owner: self) as? TextCell ?? TextCell()
            cell.textField?.stringValue = Formatting.text(for: item, column: column, relativeDates: settings.presentation.list.relativeDates)
            cell.textField?.alignment = column == .size ? .right : .left
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        let ids = items(atRows: tableView.selectedRowIndexes)
        let anchorRow = tableView.selectedRow
        let anchor = anchorRow >= 0 ? items(atRows: IndexSet(integer: anchorRow)).first : nil
        host?.contentSelectionChanged(Set(ids), anchor: anchor)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return }
        host?.contentHeaderClicked(column.sortKey, shift: NSEvent.modifierFlags.contains(.shift))
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard case .item(let i) = rows[row], tableColumn?.identifier.rawValue == ListColumn.name.rawValue else { return nil }
        return snapshot.items[i].displayName
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

/// Table subclass: Space for Quick Look, context menus via the host.
final class BrowserTableView: NSTableView {
    weak var owner: ListContentViewController?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            owner?.host?.contentToggleQuickLook()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return owner?.menu(forRow: row)
    }
}

private final class NameCell: NSTableCellView {
    private var itemID: FileID?

    init() {
        super.init(frame: .zero)
        identifier = .init("name")
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for v in [image, text] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
        textField = text
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: FileItem) {
        itemID = item.id
        textField?.stringValue = item.displayName
        imageView?.image = IconProvider.shared.icon(for: item)
        alphaValue = item.flags.contains(.hidden) ? 0.6 : 1
        IconProvider.shared.loadFileIcon(for: item) { [weak self] image in
            guard self?.itemID == item.id else { return }
            self?.imageView?.image = image
        }
    }
}

private final class TextCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        identifier = .init("text")
        let text = NSTextField(labelWithString: "")
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = text
    }

    required init?(coder: NSCoder) { fatalError() }
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
