import AppKit
import RFModel

/// Icon view (DESIGN.md §5.5): a grid of icons with thumbnails, one section per group.
@MainActor
final class IconContentViewController: NSViewController, ContentView {
    weak var host: ContentHost?

    private let collectionView = BrowserCollectionView()
    private let scrollView = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let freeLayout = FreeIconLayout()
    /// Sort By None: items sit where they were put (one section; groups don't apply).
    private(set) var isFree = false
    private var dragStart: NSPoint?
    private var draggedIndices: [Int] = []
    private var snapshot = ItemSnapshot.empty
    private var settings = ViewSettings()
    private var isApplying = false

    var firstResponderView: NSView { collectionView }

    override func loadView() {
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.textBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.owner = self
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.registerForDraggedTypes(DragAndDrop.acceptedTypes)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link, .delete], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        collectionView.register(GroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: GroupHeader.identifier)
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    // MARK: ContentView

    func apply(_ snapshot: ItemSnapshot, settings: ViewSettings) {
        isApplying = true
        defer { isApplying = false }
        // Turning on Snap to Grid lines up the icons that are already there.
        let snapTurnedOn = settings.presentation.icon.snapToGrid && !self.settings.presentation.icon.snapToGrid
            && settings.arrangement.primary.key == .manual && self.settings.arrangement.primary.key == .manual
        self.snapshot = snapshot
        self.settings = settings
        let icon = settings.presentation.icon
        let labelHeight: CGFloat = 34
        layout.itemSize = NSSize(width: max(icon.iconSize + 36, 84), height: icon.iconSize + labelHeight + 12)
        layout.minimumInteritemSpacing = icon.gridSpacing / 2
        layout.minimumLineSpacing = icon.gridSpacing / 2
        layout.sectionInset = NSEdgeInsets(top: 10, left: 14, bottom: 14, right: 14)
        layout.headerReferenceSize = snapshot.groups.isEmpty ? .zero : NSSize(width: 0, height: 28)
        isFree = settings.arrangement.primary.key == .manual
        if isFree {
            layoutFreely()
            if collectionView.collectionViewLayout !== freeLayout { collectionView.collectionViewLayout = freeLayout }
        } else if collectionView.collectionViewLayout !== layout {
            collectionView.collectionViewLayout = layout
        }
        collectionView.reloadData()
        if snapTurnedOn { cleanUp() }
    }

    // MARK: Free arrangement (Sort By None)

    private var folder: URL? { host?.state.location.folderURL }

    var arrangementGrid: FreeArrangement {
        FreeArrangement(cellSize: layout.itemSize, spacing: settings.presentation.icon.gridSpacing / 2,
                        width: max(scrollView.contentSize.width, layout.itemSize.width + 28))
    }

    /// Saved positions, plus grid cells for items that have none (which are then saved, so they
    /// stay put when other items come and go).
    private func layoutFreely() {
        let names = snapshot.items.map(\.name)
        let saved = folder.map(AppModel.shared.iconPositions(in:)) ?? [:]
        let frames = arrangementGrid.frames(for: names, saved: saved)
        freeLayout.frames = frames
        freeLayout.minimumSize = scrollView.contentSize
        freeLayout.invalidateLayout()
        if let folder {
            var new: [String: CGPoint] = [:]
            for (name, frame) in zip(names, frames) where saved[name] == nil { new[name] = frame.origin }
            if !new.isEmpty { AppModel.shared.setIconPositions(new, in: folder) }
        }
    }

    /// Where each item is drawn now (by name), to keep the arrangement when switching to None.
    func currentPositions() -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        let active = collectionView.collectionViewLayout
        for section in 0..<numberOfSections(in: collectionView) {
            for item in 0..<self.collectionView(collectionView, numberOfItemsInSection: section) {
                let path = IndexPath(item: item, section: section)
                if let frame = active?.layoutAttributesForItem(at: path)?.frame {
                    out[snapshot.items[index(of: path)].name] = frame.origin
                }
            }
        }
        return out
    }

    /// View › Clean Up: every icon to the nearest grid cell.
    func cleanUp() {
        guard isFree, let folder else { return }
        let snapped = arrangementGrid.snapped(Dictionary(uniqueKeysWithValues: zip(snapshot.items.map(\.name), freeLayout.frames.map(\.origin))))
        AppModel.shared.setIconPositions(snapped, in: folder, replacing: true)
        apply(snapshot, settings: settings)
    }

    /// Tests: what a drag of `indices` starting at `start` would record.
    func beginDragForTesting(_ indices: [Int], at start: NSPoint) {
        dragStart = start
        draggedIndices = indices
    }

    var framesForTesting: [NSRect] { freeLayout.frames }

    /// Moves the dragged icons by the distance the drag travelled.
    func moveDragged(to point: NSPoint) {
        guard isFree, let folder, let start = dragStart else { return }
        let dx = point.x - start.x, dy = point.y - start.y
        var moved: [String: CGPoint] = [:]
        for i in draggedIndices where freeLayout.frames.indices.contains(i) {
            let o = freeLayout.frames[i].origin
            moved[snapshot.items[i].name] = CGPoint(x: max(0, o.x + dx), y: max(0, o.y + dy))
        }
        if settings.presentation.icon.snapToGrid {
            var others: [String: CGPoint] = [:]
            for (i, item) in snapshot.items.enumerated() where moved[item.name] == nil && freeLayout.frames.indices.contains(i) {
                others[item.name] = freeLayout.frames[i].origin
            }
            moved = arrangementGrid.snapped(moved, others: others)
        }
        AppModel.shared.setIconPositions(moved, in: folder)
        apply(snapshot, settings: settings)
    }

    func showSelection(_ ids: Set<FileID>, reveal: FileID?) {
        isApplying = true
        defer { isApplying = false }
        collectionView.selectionIndexPaths = Set(ids.compactMap(indexPath(for:)))
        if let reveal, let path = indexPath(for: reveal) {
            collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        }
    }

    func screenFrame(for id: FileID) -> NSRect? {
        guard let path = indexPath(for: id), let window = view.window,
              let item = collectionView.item(at: path) as? IconItem else { return nil }
        let frame = item.iconFrame
        return window.convertToScreen(item.view.convert(frame, to: nil))
    }

    func nameFrameInWindow(for id: FileID) -> NSRect? {
        guard let path = indexPath(for: id) else { return nil }
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: path) as? IconItem else { return nil }
        return item.labelFrameInWindow
    }

    // MARK: Index mapping (sections = groups)

    fileprivate func index(of path: IndexPath) -> Int {
        snapshot.groups.isEmpty || isFree ? path.item : snapshot.groups[path.section].range.lowerBound + path.item
    }

    private func indexPath(for id: FileID) -> IndexPath? {
        guard let i = snapshot.index(of: id) else { return nil }
        if snapshot.groups.isEmpty || isFree { return IndexPath(item: i, section: 0) }
        guard let s = snapshot.groups.firstIndex(where: { $0.range.contains(i) }) else { return nil }
        return IndexPath(item: i - snapshot.groups[s].range.lowerBound, section: s)
    }

    fileprivate func ids(at paths: Set<IndexPath>) -> [FileID] {
        paths.map { snapshot.items[index(of: $0)].id }
    }

    private func reportSelection() {
        guard !isApplying else { return }
        let ids = ids(at: collectionView.selectionIndexPaths)
        host?.contentSelectionChanged(Set(ids), anchor: nil)
    }

    fileprivate func doubleClick(at point: NSPoint) {
        guard let path = collectionView.indexPathForItem(at: point) else { return }
        host?.contentOpen([snapshot.items[index(of: path)].id], inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    fileprivate func menu(at point: NSPoint) -> NSMenu? {
        guard let path = collectionView.indexPathForItem(at: point) else {
            collectionView.deselectAll(nil)
            reportSelection()
            return host?.contentMenu(clicked: nil)
        }
        if !collectionView.selectionIndexPaths.contains(path) {
            collectionView.selectionIndexPaths = [path]
            reportSelection()
        }
        return host?.contentMenu(clicked: snapshot.items[index(of: path)].id)
    }
}

extension IconContentViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { isFree ? 1 : max(snapshot.groups.count, 1) }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        snapshot.groups.isEmpty || isFree ? snapshot.items.count : snapshot.groups[section].range.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath) as! IconItem
        cell.configure(snapshot.items[index(of: indexPath)], options: settings.presentation.icon,
                       scale: view.window?.backingScaleFactor ?? 2)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GroupHeader.identifier, for: indexPath) as! GroupHeader
        header.label.stringValue = snapshot.groups.isEmpty ? "" : snapshot.groups[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        guard let window = collectionView.window else { return }
        dragStart = collectionView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        draggedIndices = indexPaths.map(index(of:))
    }

    /// A drag that started here and ends in empty space just moves the icons (Sort By None).
    private func isRearranging(_ info: any NSDraggingInfo, onto folder: FileItem?) -> Bool {
        isFree && folder == nil && (info.draggingSource as? NSCollectionView) === collectionView
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        snapshot.items[index(of: indexPath)].url as NSURL
    }

    /// Drops onto a folder go into it; anywhere else, into the folder being shown.
    func collectionView(_ collectionView: NSCollectionView, validateDrop info: any NSDraggingInfo,
                        proposedIndexPath path: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let proposed = path.pointee as IndexPath
        var onFolder: FileItem?
        if dropOperation.pointee == .on, proposed.section < numberOfSections(in: collectionView),
           proposed.item < self.collectionView(collectionView, numberOfItemsInSection: proposed.section) {
            let item = snapshot.items[index(of: proposed)]
            if item.isNavigableFolder, !draggedIndices.contains(index(of: proposed)) || (info.draggingSource as? NSCollectionView) !== collectionView {
                onFolder = item
            }
        }
        if isRearranging(info, onto: onFolder) {
            SpringLoading.hover(nil)
            return .move
        }
        if let item = onFolder {
            let op = DragAndDrop.operation(info, to: item.url)
            SpringLoading.hover(op.isEmpty ? nil : item.url) { [weak self] url in self?.host?.state.navigate(to: .folder(url)) }
            return op
        }
        SpringLoading.hover(nil)
        guard let here = host?.state.location.folderURL else { return [] }
        dropOperation.pointee = .before
        return DragAndDrop.operation(info, to: here)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: any NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        var target = host?.state.location.folderURL
        var onFolder: FileItem?
        if dropOperation == .on, indexPath.section < numberOfSections(in: collectionView),
           indexPath.item < self.collectionView(collectionView, numberOfItemsInSection: indexPath.section) {
            let item = snapshot.items[index(of: indexPath)]
            if item.isNavigableFolder, !draggedIndices.contains(index(of: indexPath)) || (info.draggingSource as? NSCollectionView) !== collectionView {
                target = item.url
                onFolder = item
            }
        }
        let point = collectionView.convert(info.draggingLocation, from: nil)
        if isRearranging(info, onto: onFolder) {
            moveDragged(to: point)
            return true
        }
        guard let target else { return false }
        // Items arriving from elsewhere appear where they were dropped.
        if isFree, onFolder == nil, let folder {
            let names = DragAndDrop.fileURLs(info).map(\.lastPathComponent)
            AppModel.shared.setIconPositions(arrangementGrid.dropPositions(names, at: point), in: folder)
        }
        return DragAndDrop.perform(info, to: target, from: host?.state)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        dragStart = nil
        draggedIndices = []
        let urls = session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DragAndDrop.draggingEnded(operation, items: urls, state: host?.state)
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
}

/// Collection subclass: double-click, Space for Quick Look, type-select and context menus.
final class BrowserCollectionView: NSCollectionView {
    weak var owner: IconContentViewController?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { owner?.doubleClick(at: convert(event.locationInWindow, from: nil)) }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            owner?.host?.contentToggleQuickLook()
            return
        }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
            owner?.host?.contentRename()   // Return / Enter: rename, like Finder
            return
        }
        if let chars = event.typeSelectCharacters {
            owner?.host?.contentTypeSelect(chars)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: convert(event.locationInWindow, from: nil))
    }
}

private final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let iconView = NSImageView()
    private let iconBackground = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let dots = TagDotsView()
    private let cloud = CloudBadgeView()
    private var item: FileItem?
    private var iconSize: CGFloat = 64

    var iconFrame: NSRect { iconView.frame }
    var labelFrameInWindow: NSRect { label.convert(label.bounds, to: nil) }

    override func loadView() {
        view = NSView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        for v in [iconBackground, iconView, label, dots, cloud] { view.addSubview(v) }
    }

    func configure(_ item: FileItem, options: IconOptions, scale: CGFloat) {
        self.item = item
        iconSize = options.iconSize
        label.stringValue = item.displayName
        view.alphaValue = item.flags.contains(.hidden) || FileClipboard.isCut(item.url) ? 0.5 : 1
        let provider = IconProvider.shared
        iconView.image = provider.cachedThumbnail(for: item, size: options.iconSize) ?? provider.icon(for: item)
        provider.loadFileIcon(for: item) { [weak self] image in
            guard self?.item?.id == item.id else { return }
            self?.iconView.image = image
        }
        if options.showPreviews {
            provider.loadThumbnail(for: item, size: options.iconSize, scale: scale) { [weak self] image in
                guard self?.item?.id == item.id else { return }
                self?.iconView.image = image
            }
        }
        cloud.show(for: item)
        dots.tags = TagProvider.shared.cached(item) ?? []
        TagProvider.shared.load(item) { [weak self] tags in
            guard let self, self.item?.id == item.id, self.dots.tags != tags else { return }
            self.dots.tags = tags
            self.view.needsLayout = true
        }
        view.needsLayout = true
        updateSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let iconFrame = NSRect(x: (b.width - iconSize) / 2, y: b.height - iconSize - 6, width: iconSize, height: iconSize)
        iconView.frame = iconFrame
        iconBackground.frame = iconFrame.insetBy(dx: -4, dy: -4)
        let fitted = label.sizeThatFits(NSSize(width: b.width - 4, height: 34))
        let w = min(b.width - 4, fitted.width + 8)
        label.frame = NSRect(x: (b.width - w) / 2, y: iconFrame.minY - 6 - min(fitted.height, 34), width: w, height: min(fitted.height, 34))
        // Tag dots just left of the name's first line.
        dots.frame = NSRect(x: max(0, label.frame.minX - dots.dotsWidth - 3), y: label.frame.maxY - TagDotsView.diameter - 3,
                            width: dots.dotsWidth, height: TagDotsView.diameter)
        // Not downloaded: a cloud at the icon's lower right.
        let s = CloudBadgeView.size + 2
        cloud.frame = NSRect(x: iconFrame.maxX - s / 2, y: iconFrame.minY, width: s, height: s)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let item { IconProvider.shared.cancelThumbnail(for: item, size: iconSize) }
        item = nil
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        iconBackground.layer?.backgroundColor = on ? NSColor.quaternaryLabelColor.cgColor : nil
        label.layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.cgColor : nil
        label.textColor = on ? .alternateSelectedControlTextColor : .labelColor
    }
}

private final class GroupHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
