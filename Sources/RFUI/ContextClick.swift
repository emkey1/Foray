import AppKit

/// Control-click as a right-click, everywhere in the file views and the sidebar.
///
/// AppKit only asks the one view under the pointer for a menu on a Control-click. That view is
/// usually a row, a cell or a table's background, which have none, so Control-clicking in list or
/// column view showed nothing at all, while a real right-click (which is passed up from view to
/// view) worked. This asks the same views a right-click would reach, in the same order.
@MainActor
enum ContextClick {
    private static var monitor: Any?

    /// Installed once, the first time a browser appears.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let (menu, view) = target(for: event) else { return false }
                NSMenu.popUpContextMenu(menu, with: event, for: view)
                return true
            }
            return handled ? nil : event
        }
    }

    /// The menu a Control-click should open and the view that offers it; nil to leave the click
    /// alone (not a Control-click, not in a file view or the sidebar, in a text field, or nothing
    /// there has a menu).
    static func target(for event: NSEvent) -> (NSMenu, NSView)? {
        guard event.type == .leftMouseDown,
              event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control,
              let root = event.window?.contentView,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
              !(hit is NSText), isOurs(hit) else { return nil }
        var view: NSView? = hit
        while let v = view {
            if let menu = v.menu(for: event) {
                // An empty menu means "nothing here, and don't look further" (a column that isn't
                // the current folder): the click then does what a plain click does.
                return menu.items.isEmpty ? nil : (menu, v)
            }
            if v is BackgroundMenuView || v is SidebarOutlineView { break }
            view = v.superview
        }
        return nil
    }

    /// Inside a browser's content area or the sidebar (other views handle their own clicks).
    private static func isOurs(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v {
            if current is BackgroundMenuView || current is SidebarOutlineView { return true }
            v = current.superview
        }
        return false
    }
}
