import AppKit
import RFModel

/// What a content view (icon, list, …) can ask of the browser that hosts it. Menus, keyboard
/// commands and Quick Look live in the host, so behavior is identical in every mode (DESIGN.md §5.5).
@MainActor
protocol ContentHost: AnyObject {
    var state: BrowserState { get }
    func contentSelectionChanged(_ ids: Set<FileID>, anchor: FileID?)
    func contentOpen(_ ids: [FileID], inNewTab: Bool)
    func contentMenu(clicked: FileID?) -> NSMenu?
    func contentToggleQuickLook()
    func contentTypeSelect(_ characters: String)
    func contentHeaderClicked(_ key: SortKey, shift: Bool)
    func contentPresentationChanged(_ change: (inout Presentation) -> Void)
    /// Return on a selected item: rename it in place.
    func contentRename()
}

/// Every view mode renders the same snapshot and the same selection; switching modes swaps the
/// content view without reloading or re-sorting.
@MainActor
protocol ContentView: NSViewController {
    var host: ContentHost? { get set }
    func apply(_ snapshot: ItemSnapshot, settings: ViewSettings)
    /// Programmatic selection; must not call back into `contentSelectionChanged`.
    func showSelection(_ ids: Set<FileID>, reveal: FileID?)
    func screenFrame(for id: FileID) -> NSRect?
    /// The item's name label, in window coordinates (where the rename field goes).
    func nameFrameInWindow(for id: FileID) -> NSRect?
    var firstResponderView: NSView { get }
    /// An expanded folder's contents changed (only list view shows them).
    func childrenChanged(_ id: FileID)
}

extension ContentView {
    func childrenChanged(_ id: FileID) {}
}

/// Type-to-select: accumulates keystrokes for a second and returns the item to jump to.
@MainActor
struct TypeSelectBuffer {
    private var buffer = ""
    private var last = Date.distantPast

    mutating func add(_ characters: String, in snapshot: ItemSnapshot) -> FileID? {
        if Date().timeIntervalSince(last) > 1 { buffer = "" }
        last = Date()
        buffer += characters
        let prefix = buffer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let hit = snapshot.items.first(where: {
            $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(prefix)
        }) {
            return hit.id
        }
        // Like Finder: no prefix match → the first item that sorts after what was typed.
        let key = NaturalSortKey(buffer)
        return snapshot.items.first(where: { key < $0.sortKey })?.id
    }
}

extension NSEvent {
    /// Printable characters for type-select, ignoring command shortcuts.
    var typeSelectCharacters: String? {
        guard modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let chars = characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
              chars != " " else { return nil }
        return chars
    }
}
