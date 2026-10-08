import AppKit
import RFFileSystem
import RFModel

/// Source-list sidebar: Favorites and Locations (DESIGN.md §4.1). Customization (add, remove,
/// reorder) and Tags arrive later in M1/M4.
@MainActor
final class SidebarViewController: NSViewController {
    var onNavigate: ((Location) -> Void)?

    final class Node: NSObject {
        let title: String
        let location: Location?
        let icon: NSImage?
        let ejectURL: URL?
        var children: [Node]

        init(title: String, location: Location? = nil, icon: NSImage? = nil, ejectURL: URL? = nil, children: [Node] = []) {
            self.title = title
            self.location = location
            self.icon = icon
            self.ejectURL = ejectURL
            self.children = children
        }

        var isSection: Bool { location == nil }
    }

    private let outline = NSOutlineView()
    private var sections: [Node] = []
    private var volumeObservers: [NSObjectProtocol] = []
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
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        reload()
        volumeObservers = Volumes.observeChanges { [weak self] in self?.reload() }
    }

    func reload() {
        let favorites: [StandardLocation] = [.applications, .desktop, .documents, .downloads, .home]
        let symbols: [StandardLocation: String] = [
            .applications: "app.dashed", .desktop: "menubar.dock.rectangle", .documents: "doc",
            .downloads: "arrow.down.circle", .home: "house",
        ]
        sections = [
            Node(title: "Favorites", children: favorites.compactMap { loc in
                guard let url = loc.url else { return nil }
                return Node(title: FileManager.default.displayName(atPath: url.path), location: .folder(url),
                            icon: NSImage(systemSymbolName: symbols[loc] ?? "folder", accessibilityDescription: nil))
            }),
            Node(title: "Locations", children:
                [Node(title: "Computer", location: .computer, icon: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil))]
                + Volumes.mounted().map { v in
                    Node(title: v.name, location: .folder(v.url),
                         icon: NSImage(systemSymbolName: v.isStartup ? "internaldrive" : (v.isEjectable ? "externaldrive" : "internaldrive"), accessibilityDescription: nil),
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

    @objc private func eject(_ sender: NSButton) {
        guard let node = outline.item(atRow: outline.row(for: sender)) as? Node, let url = node.ejectURL else { return }
        do {
            try Volumes.eject(url)
        } catch {
            presentError(error)
        }
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
}
