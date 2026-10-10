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
        WindowManager.shared.prefillMostRecentSearch()
        EjectUI.startWatchingUnmounts()
        FinderTakeover.applyAtLaunch()   // does nothing unless the user turned it on in Settings
        NetworkBrowser.shared.start()
        DispatchQueue.main.async { Onboarding.showIfNeeded() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Updater.shared.checkInBackgroundIfDue() }
        NSApp.activate()
    }

    private var openedFromLaunchURLs = false

    /// `open -a Foray <folder>`, drops on the Dock icon, and other apps' "Show in Finder" when Foray
    /// is the file viewer (macOS sends those as plain open-documents events naming the file).
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromLaunchURLs = true
        let files = urls.filter { !AppIntegration.open($0) }   // foray:// links are handled there
        WindowManager.shared.reveal(files)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { AppIntegration.dockMenu() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.openWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // While Foray stands in for Finder, quitting takes the desktop icons with it: ask first.
        if FinderTakeover.isEnabled, !FinderTakeover.confirmQuit() { return .terminateCancel }
        WindowManager.shared.prepareForTermination()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func newBrowserWindow(_ sender: Any?) { WindowManager.shared.openWindow() }

    @objc func showGuide(_ sender: Any?) { GuideWindowController.shared.show() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkNow() }

    @objc func connectToServer(_ sender: Any?) { ConnectToServerWindowController.shared.show() }

    /// Works with no window open, like Finder.
    @objc func emptyTrash(_ sender: Any?) { TrashUI.emptyTrash(window: NSApp.keyWindow) }

    @objc func showGuideSection(_ sender: NSMenuItem) {
        let section = (sender.representedObject as? String).flatMap(GuideWindowController.Section.init(rawValue:)) ?? .top
        GuideWindowController.shared.show(section)
    }

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
        main.addItem(submenu(appMenu(target)))
        main.addItem(submenu(fileMenu(target)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu(target)))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        main.addItem(submenu(helpMenu(target)))
        // The system adds its Help search (which mixes in unrelated results) to `NSApp.helpMenu`.
        // Point that at a menu that's never shown so our Help menu only offers the guide.
        NSApp.helpMenu = NSMenu(title: "Unused")
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

    private static func appMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let updates = item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        updates.target = target
        menu.addItem(updates)
        let settings = item("Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        settings.target = target
        menu.addItem(settings)
        menu.addItem(.separator())
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)
        let empty = item("Empty Trash…", #selector(AppDelegate.emptyTrash(_:)), backspace, [.command, .shift])
        empty.target = target
        menu.addItem(empty)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        let newWindow = item("New Foray Window", #selector(AppDelegate.newBrowserWindow(_:)), "n")
        newWindow.target = target
        menu.addItem(newWindow)
        let newTab = item("New Tab", #selector(AppDelegate.newBrowserTab(_:)), "t")
        newTab.target = target
        menu.addItem(newTab)
        menu.addItem(item("New Folder", Commands.newFolder, "n", [.command, .shift]))
        menu.addItem(item("New Folder with Selection", Commands.newFolderWithSelection, "n", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Open", Commands.openSelection, "o"))
        menu.addItem(item("Open in New Tab", Commands.openSelectionInNewTab))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Get Info", Commands.getInfo, "i"))
        menu.addItem(item("Show Inspector", Commands.showInspector, "i", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Rename", Commands.rename))
        menu.addItem(item("Duplicate", Commands.duplicate, "d"))
        menu.addItem(item("Make Alias", Commands.makeAlias, "a", [.command, .control]))
        menu.addItem(item("Compress", Commands.compress))
        menu.addItem(item("Expand", Commands.expand))
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!), f6 = String(UnicodeScalar(NSF6FunctionKey)!)
        menu.addItem(item("Copy to Other Pane", Commands.copyToOtherPane, f5, []))
        menu.addItem(item("Move to Other Pane", Commands.moveToOtherPane, f6, []))
        menu.addItem(item("Move to Trash", Commands.moveToTrash, backspace))
        menu.addItem(item("Delete Immediately…", Commands.deleteImmediately, backspace, [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Quick Look", Commands.toggleQuickLook, "y"))
        let quick = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        quick.submenu = NSMenu(title: "Quick Actions")
        quick.submenu?.addItem(item("Rotate Left", Commands.rotateLeft, "l", [.command, .control]))
        quick.submenu?.addItem(item("Rotate Right", Commands.rotateRight, "r", [.command, .control]))
        quick.submenu?.addItem(item("Markup", Commands.markup))
        quick.submenu?.addItem(item("Create PDF", Commands.createPDF))
        menu.addItem(quick)
        menu.addItem(item("Show in Enclosing Folder", Commands.showInEnclosingFolder, "r"))
        menu.addItem(item("Share…", Commands.share))
        menu.addItem(item("Eject", Commands.eject, "e"))
        menu.addItem(item("Eject All", Commands.ejectAll, "e", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Find", Commands.focusSearch, "f"))
        menu.addItem(item("Save Search…", Commands.saveSearch, "s"))
        menu.addItem(item("Copy Path", Commands.copyPath, "c", [.command, .option]))
        menu.addItem(item("Add to Sidebar", Commands.addToSidebar, "t", [.command, .control]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // NSWindow handles undo:/redo: with the window's undo manager (the app-wide file-ops stack)
        // and keeps the titles current ("Undo Move").
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Move Items Here", Commands.moveItemsHere, "v", [.command, .option]))
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
        menu.addItem(item("Clean Up", Commands.cleanUp))
        menu.addItem(item("Show View Options", Commands.showViewOptions, "j"))
        menu.addItem(.separator())
        menu.addItem(item("Reload", Commands.reloadFolder))
        menu.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Show Second Pane", Commands.toggleDualPane, "u"))
        menu.addItem(item("Switch Panes", Commands.switchPane, "u", [.command, .option]))
        menu.addItem(item("Open in Other Pane", Commands.openInOtherPane, "u", [.command, .control]))
        menu.addItem(item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu(_ target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Back", Commands.goBack, "["))
        menu.addItem(item("Forward", Commands.goForward, "]"))
        menu.addItem(item("Enclosing Folder", Commands.goEnclosing, up))
        menu.addItem(item("Open Selection", Commands.openSelection, down))
        menu.addItem(.separator())
        let places: [(String, Int, String, NSEvent.ModifierFlags)] = [
            ("Recents", 8, "f", [.command, .shift]),
            ("Computer", 1, "c", [.command, .shift]), ("Home", 2, "h", [.command, .shift]),
            ("Desktop", 3, "d", [.command, .shift]), ("Documents", 4, "o", [.command, .shift]),
            ("Downloads", 5, "l", [.command, .option]), ("Applications", 6, "a", [.command, .shift]),
            ("Utilities", 7, "u", [.command, .shift]),
        ]
        for (title, tag, key, mods) in places {
            menu.addItem(item(title, Commands.goToStandardLocation, key, mods, tag: tag))
        }
        menu.addItem(.separator())
        menu.addItem(AppIntegration.recentFoldersMenuItem())
        menu.addItem(item("Go to Folder…", Commands.goToFolder, "g", [.command, .shift]))
        let connect = item("Connect to Server…", #selector(AppDelegate.connectToServer(_:)), "k")
        connect.target = target
        menu.addItem(connect)
        return menu
    }

    private static func helpMenu(_ target: AppDelegate) -> NSMenu {
        // Not titled "Help": AppKit also looks for a menu by that title to add its search field to.
        let menu = NSMenu(title: "Help\u{200B}")
        let guide = item("Foray Guide", #selector(AppDelegate.showGuide(_:)), "?")
        guide.target = target
        menu.addItem(guide)
        for (title, section) in [("Searching", "search"), ("Search Filters", "syntax"), ("Keyboard Shortcuts", "keys")] {
            let i = item(title, #selector(AppDelegate.showGuideSection(_:)))
            i.target = target
            i.representedObject = section
            menu.addItem(i)
        }
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

/// "Foray", or "Foray Dev" for test builds.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Foray"

LegacyMigration.run()   // before anything reads preferences
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
