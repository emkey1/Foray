import AppKit
import RFModel

/// Menus shared by the menu bar, the toolbar and context menus. Items target the first
/// responder; the focused BrowserViewController implements and validates them.
@MainActor
public enum Menus {
    public static func viewModeItems() -> [NSMenuItem] {
        ViewMode.allCases.enumerated().map { i, mode in
            let item = NSMenuItem(title: "as \(mode.title)", action: #selector(BrowserViewController.setViewMode(_:)),
                                  keyEquivalent: "\(i + 1)")
            item.tag = i
            return item
        }
    }

    public static func sortMenu() -> NSMenu {
        let menu = NSMenu(title: "Sort By")
        for (i, key) in SortKey.allCases.enumerated() where key != .manual {
            let item = NSMenuItem(title: key.title, action: #selector(BrowserViewController.sortBy(_:)), keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Keep Folders on Top", action: #selector(BrowserViewController.toggleFoldersFirst(_:)), keyEquivalent: "")
        return menu
    }

    public static func groupMenu() -> NSMenu {
        let menu = NSMenu(title: "Group By")
        let none = NSMenuItem(title: "None", action: #selector(BrowserViewController.groupBy(_:)), keyEquivalent: "")
        none.tag = -1
        menu.addItem(none)
        menu.addItem(.separator())
        for (i, key) in GroupKey.allCases.enumerated() {
            let item = NSMenuItem(title: key.title, action: #selector(BrowserViewController.groupBy(_:)), keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        return menu
    }

    public static func kindFilterMenu() -> NSMenu {
        let menu = NSMenu(title: "Filter by Kind")
        menu.addItem(withTitle: "All Kinds", action: #selector(BrowserViewController.filterByKind(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        for category in KindCatalog.shared.categories {
            let item = NSMenuItem(title: category.name, action: #selector(BrowserViewController.filterByKind(_:)), keyEquivalent: "")
            item.representedObject = category.id
            item.image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// The toolbar's arrangement menu: sort, group, kind filter.
    public static func arrangementMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, sub) in [("Sort By", sortMenu()), ("Group By", groupMenu()), ("Filter by Kind", kindFilterMenu())] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        return menu
    }
}

/// Browser commands for the app's menu bar. They travel the responder chain to the focused
/// browser, which implements and validates them.
@MainActor
public enum Commands {
    public static let openSelection = #selector(BrowserViewController.openSelection(_:))
    public static let openSelectionInNewTab = #selector(BrowserViewController.openSelectionInNewTab(_:))
    public static let toggleQuickLook = #selector(BrowserViewController.toggleQuickLook(_:))
    public static let copyPath = #selector(BrowserViewController.copyPath(_:))
    public static let toggleHiddenFiles = #selector(BrowserViewController.toggleHiddenFiles(_:))
    public static let toggleRelativeDates = #selector(BrowserViewController.toggleRelativeDates(_:))
    public static let toggleRememberSettings = #selector(BrowserViewController.toggleRememberSettings(_:))
    public static let reloadFolder = #selector(BrowserViewController.reloadFolder(_:))
    public static let goBack = #selector(BrowserViewController.goBack(_:))
    public static let goForward = #selector(BrowserViewController.goForward(_:))
    public static let goEnclosing = #selector(BrowserViewController.goEnclosing(_:))
    public static let goToStandardLocation = #selector(BrowserViewController.goToStandardLocation(_:))
    public static let goToFolder = #selector(BrowserViewController.goToFolder(_:))
}
