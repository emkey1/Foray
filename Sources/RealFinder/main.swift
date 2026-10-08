import AppKit
import RFModel
import RFUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
        if !openedFromLaunchURLs && !WindowManager.shared.restoreSession() {
            WindowManager.shared.openWindow()
        }
        NSApp.activate()
    }

    private var openedFromLaunchURLs = false

    /// `open -a RealFinder <folder>` and drops on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromLaunchURLs = true
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else { continue }
            let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
            if NSApp.keyWindow != nil {
                WindowManager.shared.openTab(.folder(folder))
            } else {
                WindowManager.shared.openWindow(.folder(folder))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.openWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowManager.shared.prepareForTermination()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func newBrowserWindow(_ sender: Any?) { WindowManager.shared.openWindow() }

    @objc func newBrowserTab(_ sender: Any?) {
        guard let key = NSApp.keyWindow else { return WindowManager.shared.openWindow() }
        key.windowController?.newWindowForTab(sender)
    }
}

/// The menu bar mirrors Finder's structure and shortcuts (DESIGN.md §6.2–6.3).
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(target)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "RealFinder")
        menu.addItem(item("About RealFinder", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(item("Hide RealFinder", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit RealFinder", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        let newWindow = item("New RealFinder Window", #selector(AppDelegate.newBrowserWindow(_:)), "n")
        newWindow.target = target
        menu.addItem(newWindow)
        let newTab = item("New Tab", #selector(AppDelegate.newBrowserTab(_:)), "t")
        newTab.target = target
        menu.addItem(newTab)
        menu.addItem(item("Open", Commands.openSelection, "o"))
        menu.addItem(item("Open in New Tab", Commands.openSelectionInNewTab))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Quick Look", Commands.toggleQuickLook, "y"))
        menu.addItem(item("Show in Enclosing Folder", Commands.showInEnclosingFolder, "r"))
        menu.addItem(.separator())
        menu.addItem(item("Find", Commands.focusSearch, "f"))
        menu.addItem(item("Copy Path", Commands.copyPath, "c", [.command, .option]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(UndoManager.undo), "z"))
        menu.addItem(item("Redo", #selector(UndoManager.redo), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        Menus.viewModeItems().forEach(menu.addItem)
        menu.addItem(.separator())
        for (title, sub) in [("Sort By", Menus.sortMenu()), ("Group By", Menus.groupMenu()), ("Filter by Kind", Menus.kindFilterMenu())] {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = sub
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item("Show Hidden Files", Commands.toggleHiddenFiles, ".", [.command, .shift]))
        menu.addItem(item("Use Relative Dates", Commands.toggleRelativeDates))
        menu.addItem(item("Remember Settings for This Folder", Commands.toggleRememberSettings))
        menu.addItem(.separator())
        menu.addItem(item("Reload", Commands.reloadFolder))
        menu.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Back", Commands.goBack, "["))
        menu.addItem(item("Forward", Commands.goForward, "]"))
        menu.addItem(item("Enclosing Folder", Commands.goEnclosing, up))
        menu.addItem(item("Open Selection", Commands.openSelection, down))
        menu.addItem(.separator())
        let places: [(String, Int, String, NSEvent.ModifierFlags)] = [
            ("Computer", 1, "c", [.command, .shift]), ("Home", 2, "h", [.command, .shift]),
            ("Desktop", 3, "d", [.command, .shift]), ("Documents", 4, "o", [.command, .shift]),
            ("Downloads", 5, "l", [.command, .option]), ("Applications", 6, "a", [.command, .shift]),
            ("Utilities", 7, "u", [.command, .shift]),
        ]
        for (title, tag, key, mods) in places {
            menu.addItem(item(title, Commands.goToStandardLocation, key, mods, tag: tag))
        }
        menu.addItem(.separator())
        menu.addItem(item("Go to Folder…", Commands.goToFolder, "g", [.command, .shift]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
