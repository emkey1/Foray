import AppKit
import RFFileSystem
import RFModel
import RFOperations

/// Aliases, Compress/Expand and Share (DESIGN.md §4.4, §4.8).
extension BrowserViewController {
    static let expandableExtensions: Set<String> = ["zip"]

    var selectedAliases: [FileItem] { state.selectedItems.filter { $0.flags.contains(.alias) || $0.flags.contains(.symlink) } }
    var selectedArchives: [URL] { state.selectedItems.filter { Self.expandableExtensions.contains($0.pathExtension) }.map(\.url) }

    var compressTitle: String {
        let items = state.selectedItems
        return items.count == 1 ? "Compress “\(items[0].displayName)”" : "Compress \(items.count) Items"
    }

    /// ⌃⌘A
    @objc func makeAlias(_ sender: Any?) {
        let urls = state.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileOperationsUI.shared.submit(.makeAlias(urls), from: state)
    }

    @objc func compressSelection(_ sender: Any?) {
        let urls = state.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileOperationsUI.shared.submit(.compress(urls), from: state)
    }

    @objc func expandSelection(_ sender: Any?) {
        let archives = selectedArchives
        guard !archives.isEmpty else { return }
        FileOperationsUI.shared.submit(.expand(archives), from: state)
    }

    /// ⌘R on an alias: its original, selected in its folder.
    @objc func showOriginal(_ sender: Any?) {
        guard let alias = selectedAliases.first else { return }
        switch Aliases.resolve(alias.url) {
        case .target(let original):
            state.navigate(to: .folder(original.deletingLastPathComponent()), select: [original.lastPathComponent])
        case .broken:
            reportBrokenAlias(alias)
        case .notAnAlias:
            break
        }
    }

    /// Opening an alias or symlink: folders open here (not in Finder); files open in their app.
    /// Returns false for items that aren't aliases.
    func openAlias(_ item: FileItem, inNewTab: Bool) -> Bool {
        guard item.flags.contains(.alias) || item.flags.contains(.symlink) else { return false }
        switch Aliases.resolve(item.url) {
        case .target(let target):
            let isFolder = (try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
            if isFolder {
                if inNewTab { openInNewTab?(.folder(target)) } else { state.navigate(to: .folder(target)) }
            } else {
                NSWorkspace.shared.open(target)
            }
        case .broken:
            reportBrokenAlias(item)
        case .notAnAlias:
            return false
        }
        return true
    }

    private func reportBrokenAlias(_ alias: FileItem) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "The alias “\(alias.displayName)” can't be opened because the original item can't be found."
        alert.addButton(withTitle: "OK")
        if alias.flags.contains(.alias) { alert.addButton(withTitle: "Fix Alias…") }
        alert.addButton(withTitle: "Move Alias to Trash")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let fixIndex: NSApplication.ModalResponse = alias.flags.contains(.alias) ? .alertSecondButtonReturn : .init(-1)
            if response == fixIndex {
                self.fixAlias(alias)
            } else if response != .alertFirstButtonReturn {
                FileOperationsUI.shared.submit(.trash([alias.url]), from: self.state)
            }
        }
    }

    /// Points a broken alias at a new original.
    func fixAlias(_ alias: FileItem) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose a new original for “\(alias.displayName)”."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let original = panel.url else { return }
            do {
                try Aliases.make(to: original, at: alias.url)
                self?.state.reload()
            } catch {
                self?.presentError(error)
            }
        }
    }

    /// Share… (AirDrop, Mail, Messages and the rest), anchored to the selection.
    @objc func shareSelection(_ sender: Any?) {
        let urls = state.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor: NSView = (sender as? NSView) ?? content?.firstResponderView ?? view
        var rect = anchor.bounds
        if anchor !== sender as? NSView, let id = state.selectedItems.first?.id, let frame = content?.nameFrameInWindow(for: id) {
            rect = anchor.convert(frame, from: nil)
        }
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
}
