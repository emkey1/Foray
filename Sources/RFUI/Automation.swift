import AppKit
import RFModel
import RFOperations
import RFSearch

/// What scripts can ask Foray to do. AppleScript (Scripting.swift), Shortcuts (the app's
/// App Intents) and `foray://` links all go through here, so they behave the same.
@MainActor
public enum Automation {
    /// The windows it acts on (tests substitute their own).
    static var windows = WindowManager.shared

    private static var front: BrowserWindowController? { windows.frontController }

    // MARK: Windows

    /// Opens folders; files are shown selected in their folder.
    public static func open(_ urls: [URL]) { windows.revealing(urls) }

    /// Shows every item (folders too) selected in its enclosing folder.
    public static func reveal(_ urls: [URL]) { windows.revealing(urls, openFolders: false) }

    /// The folder the front window shows (its active pane). Nil in Computer, Recents and searches.
    public static var currentFolder: URL? { front?.browser.state.location.folderURL }

    /// Shows `folder` in the front window, or a new window if there's none.
    public static func go(to folder: URL) { windows.show(.folder(folder.standardizedFileURL)) }

    // MARK: Selection

    public static var selection: [URL] { front?.browser.state.selectedItems.map(\.url) ?? [] }

    /// Selects items. Ones in the front window's folder are selected there; anything else is
    /// shown selected in its own folder.
    public static func select(_ urls: [URL]) {
        let urls = urls.map(\.standardizedFileURL)
        if let front, let folder = front.browser.state.location.folderURL?.standardizedFileURL,
           urls.allSatisfy({ $0.deletingLastPathComponent().path == folder.path }) {
            front.browser.state.select(names: urls.map(\.lastPathComponent))
        } else {
            reveal(urls)
        }
    }

    // MARK: Dual-pane mode

    public static var isDualPane: Bool { front?.isDualPane ?? false }

    public static func setDualPane(_ on: Bool) {
        front?.setDualPane(on)
        windows.sessionChanged()
    }

    // MARK: Search

    static func query(_ text: String, in folder: URL?, contents: Bool) -> SearchQuery {
        SearchQuery(text: text, scope: folder.map { .folder($0.standardizedFileURL, recursive: true) } ?? .thisMac,
                    match: contents ? .namesAndContents : .names)
    }

    /// Runs a search in the front window (a new one if there's none). No folder means This Mac.
    public static func showSearch(_ text: String, in folder: URL? = nil, contents: Bool = false) {
        let q = query(text, in: folder, contents: contents)
        guard !q.isEmpty else { return }
        if front == nil { windows.openWindow(folder.map(Location.folder)) }
        front?.pendingSearch = nil
        front?.browser.state.runSearch(q)
        front?.window?.makeKeyAndOrderFront(nil)
    }

    /// Searches without showing anything and returns the matches, sorted by path.
    public nonisolated static func find(_ text: String, in folder: URL? = nil, contents: Bool = false, limit: Int? = nil) async -> [URL] {
        let q = SearchQuery(text: text, scope: folder.map { .folder($0.standardizedFileURL, recursive: true) } ?? .thisMac,
                            match: contents ? .namesAndContents : .names)
        guard !q.isEmpty else { return [] }
        return await SearchEngine.collect(q, limit: limit).items.map(\.url).sorted { $0.path < $1.path }
    }

    // MARK: File operations (through the app's operation engine, so Undo and Put Back work)

    /// Moves items to the Trash. Returns a message per item that couldn't be moved.
    @discardableResult
    public static func trash(_ urls: [URL]) async -> [String] {
        guard !urls.isEmpty else { return [] }
        FileOperationsUI.shared.install()
        return await OperationCenter.shared.run(.trash(urls)).errors.map(\.message)
    }
}
