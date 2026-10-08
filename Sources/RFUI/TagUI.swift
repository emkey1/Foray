import AppKit
import RFFileSystem
import RFModel
import RFOperations

/// Tags for visible items, read off the main thread and cached until the item's status-change
/// time moves (tag edits change it).
@MainActor
final class TagProvider {
    static let shared = TagProvider()

    private var cache: [FileID: (changed: Date?, tags: [Tag])] = [:]
    private var waiting: [FileID: [@MainActor ([Tag]) -> Void]] = [:]
    private let queue = DispatchQueue(label: "rf.tags", qos: .utility)

    func cached(_ item: FileItem) -> [Tag]? {
        guard let entry = cache[item.id], entry.changed == item.changed else { return nil }
        return entry.tags
    }

    func load(_ item: FileItem, completion: @escaping @MainActor ([Tag]) -> Void) {
        if let tags = cached(item) { return completion(tags) }
        if waiting[item.id] != nil {
            waiting[item.id]!.append(completion)
            return
        }
        waiting[item.id] = [completion]
        let url = item.url, id = item.id, changed = item.changed
        queue.async {
            let tags = Tags.read(at: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.cache.count > 20_000 { self.cache.removeAll() }
                    self.cache[id] = (changed, tags)
                    for c in self.waiting.removeValue(forKey: id) ?? [] { c(tags) }
                }
            }
        }
    }

    /// Tags of items whose tags are already known (for menus); unknown items count as untagged.
    func knownTags(_ items: [FileItem]) -> [[String]] { items.map { cached($0)?.map(\.name) ?? [] } }
}

extension TagColor {
    var nsColor: NSColor? {
        switch self {
        case .none: nil
        case .gray: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }
}

/// Up to three overlapping tag dots, like Finder.
final class TagDotsView: NSView {
    var tags: [Tag] = [] {
        didSet {
            isHidden = tags.isEmpty
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    static let diameter: CGFloat = 10
    static let step: CGFloat = 6

    var dotsWidth: CGFloat {
        let n = min(tags.count, 3)
        return n == 0 ? 0 : Self.diameter + CGFloat(n - 1) * Self.step
    }

    override var intrinsicContentSize: NSSize { NSSize(width: dotsWidth, height: Self.diameter) }

    override func draw(_ dirtyRect: NSRect) {
        let shown = Array(tags.filter { $0.color != .none }.prefix(3)) + (tags.allSatisfy { $0.color == .none } ? Array(tags.prefix(1)) : [])
        let y = (bounds.height - Self.diameter) / 2
        for (i, tag) in shown.enumerated() {
            let rect = NSRect(x: CGFloat(i) * Self.step, y: y, width: Self.diameter, height: Self.diameter)
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let color = tag.color.nsColor {
                color.setFill()
                path.fill()
                NSColor.windowBackgroundColor.setStroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()   // a tag without a color: an outline
            }
            path.lineWidth = 1
            path.stroke()
        }
    }

    static func image(for color: TagColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let c = color.nsColor {
                c.setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            }
            return true
        }
    }
}

// MARK: - Tag commands

extension BrowserViewController {
    /// Right-click › Tags: the color tags (and Finder's sidebar tags), checked when every selected
    /// item has them, plus Tags… for anything else.
    func tagsMenuItem() -> NSMenuItem {
        let items = state.selectedItems
        let known = TagProvider.shared.knownTags(items)
        let menu = NSMenu(title: "Tags")
        for tag in Tags.finderFavorites() {
            let mi = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            mi.representedObject = tag.name
            mi.image = TagDotsView.image(for: tag.color)
            let with = known.filter { list in list.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }.count
            mi.state = with == 0 ? .off : (with == items.count ? .on : .mixed)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tags…", action: #selector(editTags(_:)), keyEquivalent: "")
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let urls = state.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        // All have it → remove; otherwise add to the ones that don't.
        if sender.state == .on {
            FileOperationsUI.shared.submit(.changeTags(urls, add: [], remove: [name]), from: state)
        } else {
            FileOperationsUI.shared.submit(.changeTags(urls, add: [name], remove: []), from: state)
        }
    }

    /// A token field for arbitrary tags. For several items it edits the tags they share.
    @objc func editTags(_ sender: Any?) {
        let items = state.selectedItems
        guard !items.isEmpty, let window = view.window else { return }
        let known = TagProvider.shared.knownTags(items)
        let common = known.dropFirst().reduce(Set(known.first ?? [])) { $0.intersection($1) }
        let ordered = (known.first ?? []).filter { common.contains($0) }
        let field = NSTokenField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.objectValue = ordered
        field.placeholderString = "Add tags"
        field.completionDelay = 0
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Tags for “\(items[0].displayName)”" : "Tags for \(items.count) items"
        alert.informativeText = "Separate tags with commas or Return."
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let new = ((field.objectValue as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let urls = items.map(\.url)
            if items.count == 1 {
                FileOperationsUI.shared.submit(.setTags([.init(url: urls[0], tags: new)]), from: self.state)
            } else {
                let add = new.filter { !common.contains($0) }
                let remove = common.filter { !new.contains($0) }
                FileOperationsUI.shared.submit(.changeTags(urls, add: add, remove: Array(remove)), from: self.state)
            }
        }
    }
}
