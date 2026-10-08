import AppKit
import RFModel
import RFOperations

/// File commands (DESIGN.md §4.4, §5.7). They act on the selection and the current folder, and
/// go through OperationCenter, so every view mode behaves the same and everything can be undone.
extension BrowserViewController {
    /// Where Paste and New Folder put things. Nil in search results and Computer.
    var operationFolder: URL? { state.location.folderURL }

    private var selectedURLs: [URL] { state.selectedItems.map(\.url) }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        FileClipboard.write(selectedURLs, cut: false)
        refreshCutAppearance()
    }

    /// ⌘X marks items to move; ⌘V moves them (Finder can only do this with ⌘C then ⌥⌘V).
    @objc func cut(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        FileClipboard.write(selectedURLs, cut: true)
        refreshCutAppearance()
    }

    @objc func paste(_ sender: Any?) {
        guard let folder = operationFolder, let clip = FileClipboard.read() else { return }
        if clip.isCut {
            FileClipboard.clearCut()
            FileOperationsUI.shared.submit(.move(clip.urls, to: folder), from: state)
        } else {
            FileOperationsUI.shared.submit(.copy(clip.urls, to: folder), from: state)
        }
        refreshCutAppearance()
    }

    /// ⌥⌘V: move the copied items here (Finder's Move Item Here).
    @objc func moveItemsHere(_ sender: Any?) {
        guard let folder = operationFolder, let clip = FileClipboard.read() else { return }
        FileClipboard.clearCut()
        FileOperationsUI.shared.submit(.move(clip.urls, to: folder), from: state)
        refreshCutAppearance()
    }

    func refreshCutAppearance() {
        invalidateRenderedContent()
    }

    // MARK: Create, duplicate, remove

    @objc func duplicate(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        FileOperationsUI.shared.submit(.duplicate(selectedURLs), from: state)
    }

    /// Creates "untitled folder" and starts renaming it, like Finder.
    @objc func newFolder(_ sender: Any?) {
        guard let folder = operationFolder else { return }
        FileOperationsUI.shared.submit(.newFolder(in: folder), from: state) { [weak self] result in
            guard let created = result.created.first else { return }
            self?.renameWhenVisible(created)
        }
    }

    @objc func newFolderWithSelection(_ sender: Any?) {
        guard let folder = operationFolder, !selectedURLs.isEmpty else { return }
        let items = selectedURLs.filter { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
        FileOperationsUI.shared.submit(.newFolder(in: folder, name: "New Folder With Items", moving: items), from: state) { [weak self] result in
            guard let created = result.created.first else { return }
            self?.renameWhenVisible(created)
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        // In the Trash, ⌘⌫ is Put Back (like Finder).
        if !selectedTrashedURLs.isEmpty { return putBack(sender) }
        FileOperationsUI.shared.submit(.trash(selectedURLs), from: state)
    }

    /// ⌥⌘⌫: permanent, so it asks first (and can't be undone).
    @objc func deleteImmediately(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to delete these \(urls.count) items?"
        alert.informativeText = "This item will be deleted immediately. You can't undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            FileOperationsUI.shared.submit(.delete(urls), from: self.state)
        }
    }

    // MARK: Rename (Return)

    @objc func renameSelection(_ sender: Any?) {
        guard state.selectedItems.count == 1, let item = state.selectedItems.first else { return }
        beginRename(item)
    }

    /// After New Folder: wait for the new item to show up, then rename it.
    func renameWhenVisible(_ url: URL, attempts: Int = 40) {
        state.select(names: [url.lastPathComponent])
        if let item = state.snapshot.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            content?.showSelection([item.id], reveal: item.id)
            DispatchQueue.main.async { self.beginRename(item) }
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.renameWhenVisible(url, attempts: attempts - 1) }
        }
    }

    func validateFileCommand(_ item: NSMenuItem) -> Bool? {
        let hasSelection = !state.selectedItems.isEmpty
        switch item.action {
        case #selector(moveToTrash(_:)):
            item.title = !selectedTrashedURLs.isEmpty ? "Put Back" : "Move to Trash"
            return hasSelection && state.location != .computer
        case #selector(putBack(_:)):
            return !selectedTrashedURLs.isEmpty
        case #selector(emptyTrash(_:)):
            return true
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)), #selector(deleteImmediately(_:)):
            return hasSelection && state.location != .computer
        case #selector(paste(_:)):
            if let clip = FileClipboard.read() {
                item.title = clip.isCut
                    ? (clip.urls.count == 1 ? "Move “\(clip.urls[0].lastPathComponent)” Here" : "Move \(clip.urls.count) Items Here")
                    : (clip.urls.count == 1 ? "Paste “\(clip.urls[0].lastPathComponent)”" : "Paste \(clip.urls.count) Items")
            } else {
                item.title = "Paste"
            }
            return operationFolder != nil && FileClipboard.hasFiles
        case #selector(moveItemsHere(_:)):
            return operationFolder != nil && FileClipboard.hasFiles
        case #selector(newFolder(_:)):
            return operationFolder != nil
        case #selector(newFolderWithSelection(_:)):
            return operationFolder != nil && hasSelection
        case #selector(renameSelection(_:)):
            return state.selectedItems.count == 1 && state.location != .computer
        default:
            return nil
        }
    }
}
