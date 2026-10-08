import AppKit
import RFFileSystem
import RFModel
import RFOperations

/// The Trash location (DESIGN.md §5.7): Put Back, Delete Immediately and Empty Trash.
@MainActor
public enum TrashUI {
    static var icon: NSImage? { NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash") }

    /// Asks first (unless Option is held, like Finder), then deletes everything in every Trash.
    public static func emptyTrash(window: NSWindow?) { emptyTrash(window: window, from: nil) }

    static func emptyTrash(window: NSWindow?, from state: BrowserState?) {
        let folders = TrashFolders.all()
        let run = { _ = FileOperationsUI.shared.submit(.emptyTrash(folders), from: state) }
        if NSEvent.modifierFlags.contains(.option) { return run() }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { run() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            run()
        }
    }

    /// Items directly inside a Trash folder (the ones Put Back applies to).
    static func trashedItems(_ urls: [URL]) -> [URL] {
        let folders = TrashFolders.all()
        return urls.filter { TrashFolders.isTopLevelItem($0, in: folders) }
    }
}

/// Shown at the top of the Trash: what it is, and the Empty button.
@MainActor
final class TrashBar: NSView {
    var onEmpty: (() -> Void)?
    private let empty = NSButton(title: "Empty…", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Trash")
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let note = NSTextField(labelWithString: "Items here are erased when you empty the Trash. Put Back (⌘⌫) returns them.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        empty.controlSize = .small
        empty.bezelStyle = .push
        empty.target = self
        empty.action = #selector(emptyClicked)
        let separator = NSBox()
        separator.boxType = .separator
        for v in [title, note, empty, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: empty.leadingAnchor, constant: -8),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(isEmpty: Bool) { empty.isEnabled = !isEmpty }

    @objc private func emptyClicked() { onEmpty?() }
}

extension BrowserViewController {
    /// Selected items that are in the Trash.
    var selectedTrashedURLs: [URL] {
        let urls = state.selectedItems.map(\.url)
        // Cheap check first: this runs on every menu validation.
        guard state.location == .trash || urls.contains(where: { $0.path.contains("/.Trash") }) else { return [] }
        return TrashUI.trashedItems(urls)
    }

    /// ⌘⌫ in the Trash. Items with a Put Back record go back where they came from (recreating the
    /// folder if needed); for the rest, the user picks a folder.
    @objc func putBack(_ sender: Any?) {
        let items = selectedTrashedURLs
        guard !items.isEmpty else { return }
        let destinations = OperationCenter.shared.putBackDestinations(for: items)
        let pairs = items.compactMap { item in destinations[item].map { OperationRequest.Pair(from: item, to: $0) } }
        if !pairs.isEmpty { FileOperationsUI.shared.submit(.putBack(pairs), from: state) }
        let unknown = items.filter { destinations[$0] == nil }
        guard !unknown.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Put Back"
        panel.message = unknown.count == 1
            ? "RealFinder doesn't know where “\(unknown[0].lastPathComponent)” came from. Choose a folder for it."
            : "RealFinder doesn't know where \(unknown.count) of these items came from. Choose a folder for them."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let folder = panel.url else { return }
            FileOperationsUI.shared.submit(.move(unknown, to: folder), from: self.state)
        }
    }

    @objc func emptyTrash(_ sender: Any?) { TrashUI.emptyTrash(window: view.window, from: state) }
}
