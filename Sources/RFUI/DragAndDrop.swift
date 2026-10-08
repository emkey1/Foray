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

    /// Files, plus file promises (attachments from Mail, photos from Photos, images from Safari).
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func promises(_ info: any NSDraggingInfo) -> [NSFilePromiseReceiver] {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// What dropping here would do: .move, .copy, or [] (not allowed).
    static func operation(_ info: any NSDraggingInfo, to folder: URL) -> NSDragOperation {
        let urls = fileURLs(info)
        if urls.isEmpty, !promises(info).isEmpty { return .copy }   // the source app writes the files here
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
        SpringLoading.cancel()
        let op = operation(info, to: folder)
        let urls = fileURLs(info)
        if urls.isEmpty {
            let receivers = promises(info)
            guard !receivers.isEmpty else { return false }
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { _, error in
                    guard let error else { return }
                    DispatchQueue.main.async { NSApp.presentError(error) }
                }
            }
            return true
        }
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

/// Spring-loaded folders (DESIGN.md §4.1): hovering a drag over a folder opens it after a moment,
/// so items can be dropped deep inside without letting go.
@MainActor
enum SpringLoading {
    static var delay: TimeInterval = 0.8
    private static var target: URL?
    private static var timer: Timer?
    /// Tests stand in for "the mouse button is still down".
    static var isDragging: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// Called as a drag moves. The same folder for `delay` seconds opens it.
    static func hover(_ folder: URL?, open: (@MainActor (URL) -> Void)? = nil) {
        guard folder != target else { return }
        cancel()
        guard let folder, let open else { return }
        target = folder
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard target == folder, isDragging() else { return cancel() }
                cancel()
                NSSound(named: "Pop")?.play()
                open(folder)
            }
        }
    }

    static func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}
