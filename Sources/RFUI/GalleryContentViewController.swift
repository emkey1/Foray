import AppKit
import Quartz
import RFFileSystem
import RFModel

/// Gallery view (DESIGN.md §5.5): a large preview of the selected item, a filmstrip of
/// thumbnails in the shared order (§3.3), and an info panel.
@MainActor
final class GalleryContentViewController: NSViewController, ContentView {
    weak var host: ContentHost?

    private let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), style: .normal)!
    private let strip = GalleryStripView()
    private let stripScroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let info = NSTextField(wrappingLabelWithString: "")
    private let infoTitle = NSTextField(wrappingLabelWithString: "")
    private var infoWidth: NSLayoutConstraint?
    private var stripHeight: NSLayoutConstraint?
    private var snapshot = ItemSnapshot.empty
    private var settings = ViewSettings()
    private var isApplying = false
    private var shownURL: URL?
    private var shownModified: Date?
    /// Quick Actions under the info, like Finder's gallery: they go to the browser through the responder chain.
    private let actions = NSStackView()
    private let rotateButton = NSButton(title: "Rotate Left", image: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: nil)!,
                                        target: nil, action: #selector(BrowserViewController.rotateLeft(_:)))
    private let markupButton = NSButton(title: "Markup", image: NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)!,
                                        target: nil, action: #selector(BrowserViewController.markup(_:)))
    private let pdfButton = NSButton(title: "Create PDF", image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)!,
                                     target: nil, action: #selector(BrowserViewController.createPDF(_:)))

    var firstResponderView: NSView { strip }

    override func loadView() {
        let root = NSView()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        strip.collectionViewLayout = layout
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.backgroundColors = [.windowBackgroundColor]
        strip.dataSource = self
        strip.delegate = self
        strip.owner = self
        strip.register(GalleryThumb.self, forItemWithIdentifier: GalleryThumb.identifier)
        stripScroll.documentView = strip
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true

        infoTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.textColor = .secondaryLabelColor
        for b in [rotateButton, markupButton, pdfButton] {
            b.controlSize = .small
            b.bezelStyle = .push
            b.imagePosition = .imageLeading
        }
        actions.setViews([rotateButton, markupButton, pdfButton], in: .leading)
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 4
        let infoStack = NSStackView(views: [infoTitle, info, actions])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8
        infoStack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)

        let separator = NSBox()
        separator.boxType = .separator
        for v in [preview, stripScroll, infoStack, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        infoWidth = infoStack.widthAnchor.constraint(equalToConstant: 240)
        stripHeight = stripScroll.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: infoStack.leadingAnchor),
            preview.bottomAnchor.constraint(equalTo: separator.topAnchor),
            infoStack.topAnchor.constraint(equalTo: root.topAnchor),
            infoStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: separator.topAnchor),
            infoWidth!,
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: stripScroll.topAnchor),
            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripHeight!,
        ])
        view = root
    }

    // MARK: ContentView

    func apply(_ snapshot: ItemSnapshot, settings: ViewSettings) {
        isApplying = true
        defer { isApplying = false }
        self.snapshot = snapshot
        self.settings = settings
        let size = settings.presentation.gallery.thumbnailSize
        layout.itemSize = NSSize(width: size + 12, height: size + 12)
        stripHeight?.constant = size + 32
        infoWidth?.constant = settings.presentation.gallery.showMetadata ? 240 : 0
        strip.reloadData()
        // Gallery always shows something: select the first item if nothing is selected.
        if let state = host?.state, state.selection.isEmpty, let first = snapshot.items.first, state.loadState == .complete {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.host?.state.selection.isEmpty == true else { return }
                self.host?.contentSelectionChanged([first.id], anchor: first.id)
                self.showSelection([first.id], reveal: first.id)
            }
        }
        updatePreview()
    }

    func showSelection(_ ids: Set<FileID>, reveal: FileID?) {
        isApplying = true
        defer { isApplying = false }
        strip.selectionIndexPaths = Set(ids.compactMap { id in snapshot.index(of: id).map { IndexPath(item: $0, section: 0) } })
        if let reveal, let i = snapshot.index(of: reveal) {
            strip.scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .centeredHorizontally)
        }
        updatePreview()
    }

    func screenFrame(for id: FileID) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(preview.convert(preview.bounds, to: nil))
    }

    /// Gallery has no editable label; rename happens over the info panel's title.
    func nameFrameInWindow(for id: FileID) -> NSRect? {
        guard snapshot.index(of: id) != nil else { return nil }
        return infoTitle.convert(infoTitle.bounds, to: nil)
    }

    /// The previewed item: the focus anchor if selected, else the first selected item.
    private var focusedItem: FileItem? {
        guard let state = host?.state else { return nil }
        if let a = state.focusAnchor, state.selection.contains(a), let item = state.item(a) { return item }
        return state.selectedItems.first
    }

    private func updatePreview() {
        let item = focusedItem
        let url = item.flags(contains: .dataless) ? nil : item?.url   // never trigger a download
        if url != shownURL, view.window != nil {
            preview.previewItem = url as NSURL?
            shownURL = url
            shownModified = item?.modified
        } else if url != nil, item?.modified != shownModified {
            preview.refreshPreviewItem()   // the file changed (e.g. rotated)
            shownModified = item?.modified
        }
        let selected = host?.state.selectedItems ?? []
        let rotatable = !selected.isEmpty && selected.allSatisfy { QuickActions.canRotate($0.contentType) && !$0.flags.contains(.dataless) }
        rotateButton.isHidden = !rotatable
        markupButton.isHidden = !(rotatable && selected.count == 1 && MarkupSession.isAvailable)
        pdfButton.isHidden = !(!selected.isEmpty && selected.allSatisfy { QuickActions.canCombineIntoPDF($0.contentType) })
        infoTitle.stringValue = item?.displayName ?? ""
        guard let item else {
            info.stringValue = ""
            return
        }
        var lines = ["\(KindNames.name(for: item)) — \(Formatting.size(for: item))"]
        lines.append("Created  \(Formatting.date(item.created, relative: false))")
        lines.append("Modified  \(Formatting.date(item.modified, relative: false))")
        if let added = item.added { lines.append("Added  \(Formatting.date(added, relative: false))") }
        let count = host?.state.selection.count ?? 0
        if count > 1 { lines.append("\n\(count) items selected") }
        info.stringValue = lines.joined(separator: "\n")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        shownURL = nil
        updatePreview()
    }

    fileprivate func reportSelection() {
        guard !isApplying else { return }
        let ids = strip.selectionIndexPaths.compactMap { $0.item < snapshot.items.count ? snapshot.items[$0.item].id : nil }
        let anchor = strip.selectionIndexPaths.max().map { snapshot.items[$0.item].id }
        host?.contentSelectionChanged(Set(ids), anchor: anchor)
        updatePreview()
    }

    fileprivate func doubleClick(at point: NSPoint) {
        guard let path = strip.indexPathForItem(at: point) else { return }
        host?.contentOpen([snapshot.items[path.item].id], inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    fileprivate func menu(at point: NSPoint) -> NSMenu? {
        guard let path = strip.indexPathForItem(at: point) else { return host?.contentMenu(clicked: nil) }
        if !strip.selectionIndexPaths.contains(path) {
            strip.selectionIndexPaths = [path]
            reportSelection()
        }
        return host?.contentMenu(clicked: snapshot.items[path.item].id)
    }
}

private extension Optional where Wrapped == FileItem {
    func flags(contains flag: ItemFlags) -> Bool { self?.flags.contains(flag) ?? false }
}

extension GalleryContentViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { snapshot.items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: GalleryThumb.identifier, for: indexPath) as! GalleryThumb
        cell.configure(snapshot.items[indexPath.item], size: settings.presentation.gallery.thumbnailSize,
                       scale: view.window?.backingScaleFactor ?? 2)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
}

/// The filmstrip: double-click opens, Space previews, Return renames, typing selects.
final class GalleryStripView: NSCollectionView {
    weak var owner: GalleryContentViewController?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { owner?.doubleClick(at: convert(event.locationInWindow, from: nil)) }
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.charactersIgnoringModifiers == " " && plain { return owner?.host?.contentToggleQuickLook() ?? () }
        if plain && (event.keyCode == 36 || event.keyCode == 76) { return owner?.host?.contentRename() ?? () }
        if let chars = event.typeSelectCharacters { return owner?.host?.contentTypeSelect(chars) ?? () }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: convert(event.locationInWindow, from: nil))
    }
}

private final class GalleryThumb: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryThumb")
    private let image = NSImageView()
    private var item: FileItem?
    private var size: CGFloat = 64

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        image.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(image)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        image.frame = view.bounds.insetBy(dx: 6, dy: 6)
    }

    func configure(_ item: FileItem, size: CGFloat, scale: CGFloat) {
        self.item = item
        self.size = size
        view.toolTip = item.displayName
        view.alphaValue = item.flags.contains(.hidden) || FileClipboard.isCut(item.url) ? 0.5 : 1
        let provider = IconProvider.shared
        image.image = provider.cachedThumbnail(for: item, size: size) ?? provider.icon(for: item)
        provider.loadFileIcon(for: item) { [weak self] img in
            guard self?.item?.id == item.id else { return }
            self?.image.image = img
        }
        provider.loadThumbnail(for: item, size: size, scale: scale) { [weak self] img in
            guard self?.item?.id == item.id else { return }
            self?.image.image = img
        }
        updateSelection()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let item { IconProvider.shared.cancelThumbnail(for: item, size: size) }
        item = nil
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
