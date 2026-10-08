import AppKit
import RFOperations

/// Finder's drag-and-drop rules (DESIGN.md §4.4): within one disk a drag moves, across disks it
/// copies; ⌥ forces a copy, ⌘ forces a move. Shared by the list, icon and sidebar views.
@MainActor
enum DragAndDrop {
    /// Source volumes per drag (validation runs on every mouse move; look volumes up once).
    private static var cachedSequence: Int?
    private static var cachedSourceVolumes: Set<String> = []

    static func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// What dropping here would do: .move, .copy, or [] (not allowed).
    static func operation(_ info: any NSDraggingInfo, to folder: URL) -> NSDragOperation {
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return [] }
        let dest = folder.standardizedFileURL.path
        for url in urls {
            let src = url.standardizedFileURL.path
            // Onto itself or into its own subfolder: never.
            if dest == src || dest.hasPrefix(src + "/") { return [] }
        }
        let mods = NSEvent.modifierFlags
        let allowed = info.draggingSourceOperationMask
        var op: NSDragOperation
        if mods.contains(.option) && !mods.contains(.command) {
            op = .copy
        } else if mods.contains(.command) && !mods.contains(.option) {
            op = .move
        } else {
            op = sameVolume(info, urls, folder) ? .move : .copy
        }
        // Moving items into the folder they're already in does nothing.
        if op == .move && urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == dest }) { return [] }
        if !allowed.contains(op) && !(op == .move && allowed.contains(.generic)) {
            op = allowed.contains(.copy) ? .copy : []
        }
        return op
    }

    /// Starts the operation for an accepted drop. Returns false if there was nothing to do.
    @discardableResult
    static func perform(_ info: any NSDraggingInfo, to folder: URL, from state: BrowserState?) -> Bool {
        let op = operation(info, to: folder)
        let urls = fileURLs(info)
        guard !op.isEmpty, !urls.isEmpty else { return false }
        FileOperationsUI.shared.submit(op == .copy ? .copy(urls, to: folder) : .move(urls, to: folder), from: state)
        return true
    }

    /// Items dragged to the Trash in the Dock come back with a .delete operation.
    static func draggingEnded(_ operation: NSDragOperation, items: [URL], state: BrowserState?) {
        guard operation.contains(.delete), !items.isEmpty else { return }
        FileOperationsUI.shared.submit(.trash(items), from: state)
    }

    private static func sameVolume(_ info: any NSDraggingInfo, _ urls: [URL], _ folder: URL) -> Bool {
        if cachedSequence != info.draggingSequenceNumber {
            cachedSequence = info.draggingSequenceNumber
            cachedSourceVolumes = Set(urls.compactMap(volumeID))
        }
        guard let dest = volumeID(folder) else { return false }
        return cachedSourceVolumes == [dest]
    }

    private static func volumeID(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier).map { "\($0)" }
    }
}
