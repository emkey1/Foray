import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFUI

extension UISerial {
    /// Dual-pane mode (DESIGN.md I12): two browsers in one window, with a private Trash and store.
    @MainActor
    @Suite(.serialized) final class DualPaneTests {
        let base = TestDirs.make("dualpane")
        let a: URL, b: URL

        deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            _ = NSApplication.shared
            a = base.appendingPathComponent("A", isDirectory: true)
            b = base.appendingPathComponent("B", isDirectory: true)
            let trash = base.appendingPathComponent("Trash", isDirectory: true)
            for d in [a, b, trash] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: a.appendingPathComponent("doc.txt").path, contents: Data("hello".utf8))
            try FileManager.default.createDirectory(at: a.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            OperationCenter.shared = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: base.appendingPathComponent("journal"))), trash: { url in
                let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
            FileOperationsUI.shared.install()
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        private func names(_ folder: URL) -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        }

        private func select(_ vc: BrowserViewController, _ name: String) {
            guard let item = vc.state.snapshot.items.first(where: { $0.name == name }) else { return }
            vc.state.setSelection([item.id], anchor: item.id)
        }

        /// A window on A with a second pane on B.
        private func dualWindow() async -> BrowserWindowController {
            let c = BrowserWindowController(location: .folder(a))
            c.setDualPane(true, location: .folder(b))
            await wait { c.panes.allSatisfy { $0.state.loadState == .complete } }
            return c
        }

        private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

        @Test func secondPaneStartsOnTheSameFolderAndHidingKeepsTheActiveOne() async {
            let c = BrowserWindowController(location: .folder(a))
            defer { c.window?.close() }
            #expect(!c.isDualPane && c.otherPane == nil && c.panes[0].paneRole == .single)
            c.toggleDualPane(nil)
            #expect(c.isDualPane && c.panes.count == 2)
            #expect(c.panes[1].state.location == .folder(a))
            #expect(c.panes.map(\.paneRole) == [.active, .inactive])

            c.panes[1].state.jump(to: .folder(b))
            c.switchPane(nil)
            #expect(c.activePaneIndex == 1 && c.browser === c.panes[1])
            #expect(c.panes.map(\.paneRole) == [.inactive, .active])
            #expect(c.window?.title == "B")                       // the chrome follows the active pane

            c.toggleDualPane(nil)                                 // hiding keeps the pane in use
            #expect(!c.isDualPane && c.browser.state.location == .folder(b))
            #expect(c.browser.paneRole == .single)
        }

        @Test func copyAndMoveToTheOtherPane() async {
            let c = await dualWindow()
            defer { c.window?.close() }
            await wait { !c.panes[0].state.snapshot.items.isEmpty }
            #expect(!c.validateMenuItem(item(Commands.copyToOtherPane)))   // nothing selected
            select(c.panes[0], "doc.txt")
            #expect(c.validateMenuItem(item(Commands.copyToOtherPane)))
            c.copyToOtherPane(nil)
            await wait { names(b) == ["doc.txt"] }
            #expect(names(a) == ["doc.txt", "Sub"] && names(b) == ["doc.txt"])
            // The copy is selected in the pane it went to.
            await wait { c.panes[1].state.selectedItems.map(\.name) == ["doc.txt"] }
            #expect(c.panes[1].state.selectedItems.map(\.name) == ["doc.txt"])

            select(c.panes[0], "Sub")
            c.moveToOtherPane(nil)
            await wait { names(b) == ["doc.txt", "Sub"] }
            #expect(names(a) == ["doc.txt"] && names(b) == ["doc.txt", "Sub"])
            // One undo stack for the window: undoing puts the folder back.
            OperationCenter.shared.undoManager.undo()
            await wait { names(a) == ["doc.txt", "Sub"] }
            #expect(names(b) == ["doc.txt"])
        }

        @Test func openInOtherPaneShowsTheSelectedFolderThere() async {
            let c = await dualWindow()
            defer { c.window?.close() }
            await wait { !c.panes[0].state.snapshot.items.isEmpty }
            select(c.panes[0], "doc.txt")
            #expect(!c.validateMenuItem(item(Commands.openInOtherPane)))   // a file, not a folder
            select(c.panes[0], "Sub")
            c.openInOtherPane(nil)
            #expect(c.panes[1].state.location == .folder(a.appendingPathComponent("Sub")))
            c.panes[0].state.setSelection([], anchor: nil)
            c.switchPane(nil)                                     // nothing selected: this pane's folder
            c.panes[1].state.setSelection([], anchor: nil)
            c.openInOtherPane(nil)
            #expect(c.panes[0].state.location == .folder(a.appendingPathComponent("Sub")))
        }

        /// Both panes lay out side by side at about the same width, and only the active one is marked.
        @Test func panesShareTheWindowEvenly() async {
            let c = await dualWindow()
            defer { c.window?.close() }
            c.window?.setContentSize(NSSize(width: 1200, height: 600))
            c.window?.contentView?.layoutSubtreeIfNeeded()
            c.setDualPane(false)
            c.setDualPane(true, location: .folder(b))
            await wait { c.panes.allSatisfy { $0.state.loadState == .complete } }
            c.window?.contentView?.layoutSubtreeIfNeeded()
            let widths = c.panes.map(\.view.frame.width)
            #expect(widths.allSatisfy { $0 >= 240 })
            #expect(abs(widths[0] - widths[1]) <= 2)
            if let dir = ProcessInfo.processInfo.environment["RF_SNAPSHOT_DIR"], let view = c.window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dualpane.png"))
            }
        }

        @Test func commandsAreOffWithOnePane() {
            let c = BrowserWindowController(location: .folder(a))
            defer { c.window?.close() }
            for action in [Commands.switchPane, Commands.copyToOtherPane, Commands.moveToOtherPane, Commands.openInOtherPane] {
                #expect(!c.validateMenuItem(item(action)))
            }
            let toggle = item(Commands.toggleDualPane)
            #expect(c.validateMenuItem(toggle) && toggle.title == "Show Second Pane")
            c.setDualPane(true)
            #expect(c.validateMenuItem(toggle) && toggle.title == "Hide Second Pane")
        }

        @Test func sidebarAndSessionFollowThePanes() async {
            let manager = WindowManager()
            manager.openWindow(.folder(a))
            let c = manager.controllersForTesting[0]
            c.setDualPane(true, location: .folder(b))
            c.setActivePane(1)
            manager.prepareForTermination()
            c.window?.close()
            let saved = AppModel.shared.loadSession()?.windows.first
            #expect(saved?.tabs == [.folder(a)])
            #expect(saved?.otherPanes == [.folder(b)])

            let restored = WindowManager()
            #expect(restored.restoreSession())
            let r = restored.controllersForTesting[0]
            defer { r.window?.close() }
            #expect(r.isDualPane)
            #expect(r.panes.map(\.state.location) == [.folder(a), .folder(b)])
        }

        @Test func sessionsWithoutASecondPaneStillLoad() throws {
            // What 0.9.2 wrote: no otherPanes key.
            let old = #"{"windows":[{"tabs":[{"folder":{"_0":"file:///tmp/"}}],"selectedTab":0}]}"#
            let session = try? JSONDecoder().decode(AppModel.Session.self, from: Data(old.utf8))
            if let session { #expect(session.windows[0].otherPanes == nil) }
            // And a new session round-trips.
            let new = AppModel.Session(windows: [.init(tabs: [.folder(a), .folder(b)], selectedTab: 1, frame: nil, otherPanes: [nil, .folder(a)])])
            let back = try JSONDecoder().decode(AppModel.Session.self, from: JSONEncoder().encode(new))
            #expect(back.windows[0].otherPanes == [nil, .folder(a)])
        }
    }
}
