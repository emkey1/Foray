import AppKit
import RFFileSystem
import RFModel

/// Eject from the sidebar, the File menu (⌘E) and the context menu. Runs off the main thread; when
/// something has files open, says what and offers Force Eject (DESIGN.md §5.9).
@MainActor
public enum EjectUI {
    /// Volumes being ejected, so a second click doesn't start another attempt.
    private static var inFlight = Set<String>()

    static func isEjectable(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]),
              v.isVolume == true, url.path != "/" else { return false }
        return v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsLocal == false
    }

    /// Eject, asking first when a volume shares its disk with others that would go too.
    static func eject(_ volumes: [URL], window: NSWindow?) {
        var queue = volumes
        func next() {
            guard let volume = queue.first else { return }
            queue.removeFirst()
            let others = Ejector.siblings(of: volume).filter { !volumes.contains($0) }
            guard !others.isEmpty else {
                run([volume], window: window, force: false)
                return next()
            }
            let name = FileManager.default.displayName(atPath: volume.path)
            let names = ListFormatter.localizedString(byJoining: others.map { "“\(FileManager.default.displayName(atPath: $0.path))”" })
            let alert = NSAlert()
            alert.messageText = "“\(name)” is on a disk with other volumes: \(names)."
            alert.informativeText = "Ejecting the disk unmounts all of them. To keep the others, unmount just “\(name)”."
            alert.addButton(withTitle: "Eject All")
            alert.addButton(withTitle: "Unmount Just “\(name)”")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                switch response {
                case .alertFirstButtonReturn: run([volume], window: window, force: false)
                case .alertSecondButtonReturn: run([volume], window: window, force: false, unmountOnly: true)
                default: break
                }
                next()
            }
            if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
        }
        next()
    }

    /// File › Eject All: every ejectable disk (and network volume).
    static func ejectAll(window: NSWindow?) {
        let volumes = Volumes.mounted().filter { $0.isEjectable || !$0.isLocal }.map(\.url)
        guard !volumes.isEmpty else { return NSSound.beep() }
        run(volumes, window: window, force: false)
    }

    static var hasEjectable: Bool { Volumes.mounted().contains { $0.isEjectable || !$0.isLocal } }

    private static func run(_ volumes: [URL], window: NSWindow?, force: Bool, unmountOnly: Bool = false) {
        for volume in volumes where inFlight.insert(volume.path).inserted {
            let name = FileManager.default.displayName(atPath: volume.path)
            Task.detached(priority: .userInitiated) {
                let failure: Ejector.Failure?
                do {
                    if unmountOnly { try Ejector.unmountOnly(volume) } else { try Ejector.eject(volume, force: force) }
                    failure = nil
                } catch let f as Ejector.Failure {
                    failure = f
                } catch {
                    failure = Ejector.Failure(message: error.localizedDescription, blockers: [])
                }
                await MainActor.run {
                    inFlight.remove(volume.path)
                    if let failure { report(failure, name: name, volume: volume, window: window, wasForced: force) }
                }
            }
        }
    }

    private static func report(_ failure: Ejector.Failure, name: String, volume: URL, window: NSWindow?, wasForced: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let names = failure.blockers.map(\.name)
        if !names.isEmpty {
            alert.messageText = "“\(name)” wasn't ejected because it's in use."
            alert.informativeText = "Quit \(ListFormatter.localizedString(byJoining: names)), or close the files they have open on “\(name)”, then try again. "
                + "Force Eject may lose unsaved changes in those apps."
        } else {
            alert.messageText = "“\(name)” wasn't ejected."
            alert.informativeText = failure.message
        }
        if !wasForced { alert.addButton(withTitle: "Force Eject") }
        alert.addButton(withTitle: wasForced ? "OK" : "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if !wasForced, response == .alertFirstButtonReturn { run([volume], window: window, force: true) }
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: Unmounts

    private static var unmountObserver: NSObjectProtocol?

    /// Tabs showing a volume that goes away move to Computer instead of showing an error.
    public static func startWatchingUnmounts() {
        guard unmountObserver == nil else { return }
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { volumeWentAway(volume) }
        }
    }

    static func volumeWentAway(_ volume: URL) {
        let root = volume.standardizedFileURL.path
        guard root != "/" else { return }
        for state in BrowserState.live {
            guard let path = state.location.folderURL?.standardizedFileURL.path else { continue }
            if path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") { state.navigate(to: .computer) }
        }
    }
}

extension BrowserViewController {
    /// The selected volumes (in Computer, or mount points anywhere).
    var selectedEjectableVolumes: [URL] {
        state.selectedItems.filter { $0.flags.contains(.mountPoint) || $0.url.path.hasPrefix("/Volumes/") }
            .map(\.url).filter(EjectUI.isEjectable)
    }

    @objc func ejectSelection(_ sender: Any?) {
        EjectUI.eject(selectedEjectableVolumes, window: view.window)
    }

    @objc func ejectAll(_ sender: Any?) { EjectUI.ejectAll(window: view.window) }
}
