import AppKit
import RFFileSystem
import RFModel
import RFSearch

/// Saving searches as smart folders, and opening them (DESIGN.md §4.6).
extension BrowserViewController {
    /// The scope bar's Save… and File › Save Search…: a `.savedSearch` file (Finder can open it),
    /// optionally added to the sidebar.
    @objc func saveSearch(_ sender: Any?) {
        guard let query = state.location.searchQuery, let window = view.window else { return }
        let folder = SavedSearch.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = (query.text.isEmpty ? "Search" : query.text.replacingOccurrences(of: "/", with: ":"))
            + "." + SavedSearch.fileExtension
        panel.allowedContentTypes = []
        panel.isExtensionHidden = true
        panel.message = "Save this search as a smart folder. It finds new matches whenever you open it."
        let addToSidebar = NSButton(checkboxWithTitle: "Add to Sidebar", target: nil, action: nil)
        addToSidebar.state = .on
        panel.accessoryView = addToSidebar
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension != SavedSearch.fileExtension { url.appendPathExtension(SavedSearch.fileExtension) }
            do {
                try SavedSearch.write(query, to: url)
                if addToSidebar.state == .on { AppModel.shared.addFavorites([url]) }
            } catch {
                self?.presentError(error)
            }
        }
    }

    /// Opening a `.savedSearch` runs it here. Returns false for other items.
    func openSmartFolder(_ item: FileItem, inNewTab: Bool) -> Bool {
        guard item.url.pathExtension == SavedSearch.fileExtension else { return false }
        guard let query = SavedSearch.read(item.url) else {
            NSWorkspace.shared.open(item.url)   // not something we can read; let Finder try
            return true
        }
        if inNewTab { openInNewTab?(.search(query)) } else { state.navigate(to: .search(query)) }
        return true
    }
}

extension SavedSearch {
    /// The sidebar entry for a smart folder kept in Favorites.
    @MainActor
    static func sidebarLocation(_ url: URL) -> Location? {
        guard url.pathExtension == fileExtension, let q = read(url) else { return nil }
        return .search(q)
    }
}
