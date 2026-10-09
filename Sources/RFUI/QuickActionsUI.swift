import AppKit
import RFFileSystem
import RFModel
import RFOperations
import UniformTypeIdentifiers

/// Quick Actions (DESIGN.md §4.2): the right-click submenu, gallery buttons and toolbar items.
extension BrowserViewController {
    var selectedRotatable: [URL] {
        let items = state.selectedItems
        guard !items.isEmpty, items.allSatisfy({ QuickActions.canRotate($0.contentType) && !$0.flags.contains(.dataless) }) else { return [] }
        return items.map(\.url)
    }

    var selectedForPDF: [URL] {
        let items = state.selectedItems
        guard !items.isEmpty, items.allSatisfy({ QuickActions.canCombineIntoPDF($0.contentType) && !$0.flags.contains(.dataless) }) else { return [] }
        return items.map(\.url)
    }

    /// One image or PDF to mark up.
    var markupTarget: URL? { selectedRotatable.count == 1 ? selectedRotatable[0] : nil }

    func quickActionsMenuItem() -> NSMenuItem? {
        let menu = NSMenu(title: "Quick Actions")
        if !selectedRotatable.isEmpty {
            menu.addItem(withTitle: "Rotate Left", action: #selector(rotateLeft(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Rotate Right", action: #selector(rotateRight(_:)), keyEquivalent: "")
        }
        if markupTarget != nil { menu.addItem(withTitle: "Markup", action: #selector(markup(_:)), keyEquivalent: "") }
        if !selectedForPDF.isEmpty { menu.addItem(withTitle: "Create PDF", action: #selector(createPDF(_:)), keyEquivalent: "") }
        guard !menu.items.isEmpty else { return nil }
        let item = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc func rotateLeft(_ sender: Any?) {
        guard !selectedRotatable.isEmpty else { return }
        FileOperationsUI.shared.submit(.rotate(selectedRotatable, clockwise: false), from: state)
    }

    @objc func rotateRight(_ sender: Any?) {
        guard !selectedRotatable.isEmpty else { return }
        FileOperationsUI.shared.submit(.rotate(selectedRotatable, clockwise: true), from: state)
    }

    @objc func createPDF(_ sender: Any?) {
        guard !selectedForPDF.isEmpty else { return }
        FileOperationsUI.shared.submit(.createPDF(selectedForPDF), from: state)
    }

    /// Markup: macOS's own editor (the one Finder's Quick Look uses), shown over this window.
    @objc func markup(_ sender: Any?) {
        guard let url = markupTarget, let window = view.window else { return }
        MarkupSession.start(url, window: window)
    }
}

/// Runs the system Markup editor on one file. The editor normally saves in place; if it hands
/// back an edited copy instead, the original goes to the Trash (so it can be recovered) and the
/// copy takes its place.
@MainActor
final class MarkupSession: NSObject, NSSharingServiceDelegate {
    static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")
    private static var active: MarkupSession?
    private let url: URL
    private weak var window: NSWindow?

    static var isAvailable: Bool { NSSharingService(named: serviceName) != nil }

    static func start(_ url: URL, window: NSWindow) {
        guard let service = NSSharingService(named: serviceName) else { return NSSound.beep() }
        let session = MarkupSession(url: url, window: window)
        active = session
        service.delegate = session
        service.perform(withItems: [url])
    }

    private init(url: URL, window: NSWindow) {
        self.url = url
        self.window = window
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { window }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let edited = items.compactMap { ($0 as? URL) ?? ($0 as? NSURL).map { $0 as URL } }
        MainActor.assumeIsolated {
            defer { Self.active = nil }
            guard let copy = edited.first, copy.standardizedFileURL != url.standardizedFileURL else { return }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try FileManager.default.copyItem(at: copy, to: url)
            } catch {
                window.map { NSAlert(error: error).beginSheetModal(for: $0) }
            }
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        MainActor.assumeIsolated { Self.active = nil }
    }
}
