import AppKit
import RFFileSystem
import RFModel

/// Go › Recent Folders, the Dock menu and `foray://` links (DESIGN.md §4.8).
@MainActor
public enum AppIntegration {
    /// Items for recent folders, newest first; choosing one shows it in the front window.
    static func recentFolderItems() -> [NSMenuItem] {
        AppModel.shared.recentFolders.filter { FileManager.default.fileExists(atPath: $0.path) }.map { url in
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: #selector(MenuTarget.openRecent(_:)), keyEquivalent: "")
            item.target = MenuTarget.shared
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            return item
        }
    }

    /// Go › Recent Folders, rebuilt each time it opens.
    public static func recentFoldersMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Recent Folders")
        menu.delegate = MenuTarget.shared
        item.submenu = menu
        return item
    }

    public static func dockMenu() -> NSMenu {
        let menu = NSMenu()
        let new = NSMenuItem(title: "New AOK-Foray Window", action: #selector(MenuTarget.newWindow(_:)), keyEquivalent: "")
        new.target = MenuTarget.shared
        menu.addItem(new)
        let recents = recentFolderItems()
        if !recents.isEmpty {
            menu.addItem(.separator())
            recents.forEach(menu.addItem)
        }
        return menu
    }

    /// foray://open?path=/Users/me/Projects        → that folder (a file: its folder, selected)
    /// foray://reveal?path=/Users/me/Projects      → its enclosing folder, with it selected
    /// foray://search?q=report%20kind:pdf&in=/path → that search ("in" omitted: This Mac)
    public static func location(for url: URL) -> (Location, select: [String])? {
        guard isOurs(url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func param(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        switch c.host?.lowercased() {
        case "open":
            guard let raw = param("path") else { return nil }
            let target = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else { return nil }
            return isDir.boolValue ? (.folder(target), []) : (.folder(target.deletingLastPathComponent()), [target.lastPathComponent])
        case "reveal":
            // Like "open", but a folder is shown selected in its parent too.
            guard let raw = param("path") else { return nil }
            let target = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: target.path), target.path != "/" else { return nil }
            return (.folder(target.deletingLastPathComponent()), [target.lastPathComponent])
        case "search":
            guard let q = param("q"), !q.isEmpty else { return nil }
            let scope: SearchScope = param("in").map { .folder(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true), recursive: true) } ?? .thisMac
            return (.search(SearchQuery(text: q, scope: scope)), [])
        default:
            return nil
        }
    }

    /// Tells AppKit what a browser's selection can be sent to Services as. Without it no service
    /// that takes files shows up (Terminal's "New Terminal at Folder", iTerm2's "New iTerm2 Window Here", …).
    public static func registerServices() {
        NSApp.registerServicesMenuSendTypes([.fileURL, BrowserViewController.filenamesType, .string], returnTypes: [])
    }

    /// foray:// (or foray-dev:// for test builds).
    static func isOurs(_ url: URL) -> Bool { ["foray", "foray-dev"].contains(url.scheme?.lowercased() ?? "") }

    /// Opens a `foray://` link. Returns false if it isn't one.
    public static func open(_ url: URL) -> Bool {
        guard let (location, select) = location(for: url) else { return isOurs(url) }
        // A search link was asked for explicitly, so it runs (a restored search tab only waits).
        if let q = location.searchQuery {
            Automation.showSearch(q.text, in: q.scope.folderURL)
            return true
        }
        if let front = NSApp.mainWindow?.windowController as? BrowserWindowController {
            front.browser.state.navigate(to: location, select: select)
        } else {
            WindowManager.shared.openWindow(location)
        }
        WindowManager.comeForward()
        return true
    }
}

@MainActor
final class MenuTarget: NSObject, NSMenuDelegate {
    static let shared = MenuTarget()

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        WindowManager.shared.show(.folder(url))
    }

    @objc func newWindow(_ sender: Any?) { WindowManager.shared.openWindow() }

    @objc func clearRecentFolders(_ sender: Any?) { AppModel.shared.clearRecentFolders() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = AppIntegration.recentFolderItems()
        items.forEach(menu.addItem)
        if items.isEmpty {
            menu.addItem(NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentFolders(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }
}

// MARK: Services (DESIGN.md §4.8): the selection as files for Services and Quick Actions.

extension BrowserWindowController {
    /// The window answers for its browser too, so Services work whatever has the focus.
    override public func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        browser.servicesRequestor(sendType, returnType) ?? super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

extension BrowserViewController: @MainActor NSServicesMenuRequestor {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        servicesRequestor(sendType, returnType) ?? super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Itself, when the selection can be sent as `sendType`.
    func servicesRequestor(_ sendType: NSPasteboard.PasteboardType?, _ returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard returnType == nil, sendType == .fileURL || sendType == .string || sendType == Self.filenamesType,
              !servicesItems.isEmpty else { return nil }
        return self
    }

    /// The selection, or with nothing selected the folder itself (as with Finder's menu inside a folder).
    private var servicesItems: [URL] {
        let selected = state.selectedItems.map(\.url)
        if !selected.isEmpty { return selected }
        if case .folder(let url) = state.location { return [url] }
        return []
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = servicesItems
        guard !urls.isEmpty else { return false }
        pboard.clearContents()
        guard pboard.writeObjects(urls as [NSURL]) else { return false }
        // As text, the paths themselves (not file:// links): services that take a folder as text,
        // like Terminal's, check that the text is a file path. (Asked for under old names too.)
        pboard.pasteboardItems?.first?.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return true
    }
}

