import AppKit
import RFFileSystem
import RFModel

/// Source-list sidebar: Favorites and Locations (DESIGN.md §4.1). Favorites are user-editable:
/// drag folders in, drag to reorder, drag out or right-click to remove. Tags arrive in M4.
@MainActor
final class SidebarViewController: NSViewController {
    var onNavigate: ((Location) -> Void)?
    var onOpenInNewTab: ((Location) -> Void)?

    final class Node: NSObject {
        let title: String
        let location: Location?
        let icon: NSImage?
        let ejectURL: URL?
        /// Index in AppModel.favorites, for favorites.
        let favoriteIndex: Int?
        var children: [Node]

        init(title: String, location: Location? = nil, icon: NSImage? = nil, ejectURL: URL? = nil,
             favoriteIndex: Int? = nil, children: [Node] = []) {
            self.title = title
            self.location = location
            self.icon = icon
            self.ejectURL = ejectURL
            self.favoriteIndex = favoriteIndex
            self.children = children
        }

        var isSection: Bool { location == nil }
    }

    static let favoriteDragType = NSPasteboard.PasteboardType("local.realfinder.sidebar-favorite")

    private let outline = SidebarOutlineView()
    private var sections: [Node] = []
    private var favoritesSection: Node? { sections.first }
    private var observers: [NSObjectProtocol] = []
    private var favoritesObserver: UUID?
    private var highlighted: Location?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.owner = self
        outline.registerForDraggedTypes([.fileURL, Self.favoriteDragType])
        outline.setDraggingSourceOperationMask([.move, .delete], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .link, .delete], forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        reload()
        observers = Volumes.observeChanges { [weak self] in self?.reload() }
        favoritesObserver = AppModel.shared.observeFavorites { [weak self] in self?.reload() }
    }

    private static let symbols: [String: String] = {
        var s: [String: String] = [:]
        let pairs: [(StandardLocation, String)] = [
            (.applications, "app.dashed"), (.desktop, "menubar.dock.rectangle"), (.documents, "doc"),
            (.downloads, "arrow.down.circle"), (.home, "house"), (.utilities, "wrench.and.screwdriver"),
        ]
        for (loc, symbol) in pairs { if let url = loc.url { s[url.standardizedFileURL.path] = symbol } }
        return s
    }()

    func reload() {
        let favorites = AppModel.shared.favorites.enumerated().map { i, url in
            Node(title: FileManager.default.displayName(atPath: url.path), location: .folder(url),
                 icon: NSImage(systemSymbolName: Self.symbols[url.standardizedFileURL.path] ?? "folder", accessibilityDescription: nil),
                 favoriteIndex: i)
        }
        sections = [
            Node(title: "Favorites", children: favorites),
            Node(title: "Locations", children:
                [Node(title: "Computer", location: .computer, icon: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil))]
                + Volumes.mounted().map { v in
                    Node(title: v.name, location: .folder(v.url),
                         icon: NSImage(systemSymbolName: v.isEjectable ? "externaldrive" : "internaldrive", accessibilityDescription: nil),
                         ejectURL: v.isEjectable ? v.url : nil)
                }),
        ]
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
        highlight(highlighted)
    }

    /// Selects the row for the browser's current location (if it's in the sidebar).
    func highlight(_ location: Location?) {
        highlighted = location
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, node.location != nil, node.location == location {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    @objc private func eject(_ sender: Any) {
        let row = (sender as? NSView).map(outline.row(for:)) ?? outline.clickedRow
        guard let node = outline.item(atRow: row) as? Node, let url = node.ejectURL else { return }
        do {
            try Volumes.eject(url)
        } catch {
            presentError(error)
        }
    }

    @objc private func removeClicked(_ sender: Any) {
        guard let index = (outline.item(atRow: outline.clickedRow) as? Node)?.favoriteIndex else { return }
        AppModel.shared.removeFavorite(at: index)
    }

    @objc private func openInNewTabClicked(_ sender: Any) {
        guard let location = (outline.item(atRow: outline.clickedRow) as? Node)?.location else { return }
        onOpenInNewTab?(location)
    }

    fileprivate func menu(forRow row: Int) -> NSMenu? {
        guard let node = outline.item(atRow: row) as? Node, !node.isSection else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTabClicked(_:)), keyEquivalent: "").target = self
        if node.favoriteIndex != nil {
            menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeClicked(_:)), keyEquivalent: "").target = self
        }
        if node.ejectURL != nil {
            menu.addItem(withTitle: "Eject “\(node.title)”", action: #selector(eject(_:)), keyEquivalent: "").target = self
        }
        return menu
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.isSection == true }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.isSection == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.isSection == false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if node.isSection {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: node.title)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let cell = NSTableCellView()
        let image = NSImageView(image: node.icon ?? NSImage())
        image.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: node.title)
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [image, label]
        if node.ejectURL != nil {
            let eject = NSButton(image: NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")!,
                                 target: self, action: #selector(eject(_:)))
            eject.isBordered = false
            eject.contentTintColor = .secondaryLabelColor
            views.append(eject)
        }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if let eject = views.last as? NSButton {
            NSLayoutConstraint.activate([
                eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            ])
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4).isActive = true
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node, let location = node.location,
              location != highlighted else { return }
        onNavigate?(location)
    }

    // MARK: Drag and drop

    /// Favorites drag as their folder (so they can be dropped on other apps) plus their index.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? Node, let index = node.favoriteIndex, case .folder(let url) = node.location else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(url.absoluteString, forType: .fileURL)
        pb.setString(String(index), forType: Self.favoriteDragType)
        return pb
    }

    /// While a favorite is dragged outside the sidebar, show the "will disappear" cursor.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard session.draggingPasteboard.string(forType: Self.favoriteDragType) != nil, let window = view.window else { return }
        let inside = view.bounds.contains(view.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        session.animatesToStartingPositionsOnCancelOrFail = inside
        (inside ? NSCursor.arrow : NSCursor.disappearingItem).set()
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let favorites = favoritesSection else { return [] }
        // Files dropped onto a favorite or a disk go into it (move/copy), like Finder.
        if let node = item as? Node, !node.isSection, index == NSOutlineViewDropOnItemIndex,
           info.draggingPasteboard.availableType(from: [Self.favoriteDragType]) == nil,
           case .folder(let url) = node.location {
            return DragAndDrop.operation(info, to: url)
        }
        // Otherwise (between rows) folders are added as favorites.
        var target = index
        if let node = item as? Node, node !== favorites {
            guard let i = node.favoriteIndex else { return [] }
            target = i + 1
        } else if item == nil || index < 0 {
            target = favorites.children.count
        }
        if info.draggingPasteboard.availableType(from: [Self.favoriteDragType]) != nil {
            outlineView.setDropItem(favorites, dropChildIndex: target)
            return .move
        }
        guard !droppedFolders(info).isEmpty else { return [] }
        outlineView.setDropItem(favorites, dropChildIndex: target)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let node = item as? Node, !node.isSection, index == NSOutlineViewDropOnItemIndex, case .folder(let url) = node.location {
            return DragAndDrop.perform(info, to: url, from: nil)
        }
        if let s = info.draggingPasteboard.string(forType: Self.favoriteDragType), let from = Int(s) {
            AppModel.shared.moveFavorite(from: from, to: index)
            return true
        }
        let folders = droppedFolders(info)
        guard !folders.isEmpty else { return false }
        AppModel.shared.addFavorites(folders, at: index)
        return true
    }

    /// Dragging a favorite out of the sidebar and letting go removes it, like Finder.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        guard operation == [] || operation == .delete,
              let s = session.draggingPasteboard.string(forType: Self.favoriteDragType), let index = Int(s),
              let window = view.window else { return }
        let inSidebar = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard !view.bounds.contains(inSidebar) else { return }
        AppModel.shared.removeFavorite(at: index)
    }

    /// Folders (not files) among the dragged URLs.
    private func droppedFolders(_ info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false }
    }
}

/// Sidebar outline with right-click menus.
final class SidebarOutlineView: NSOutlineView {
    weak var owner: SidebarViewController?

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }
}
