import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFUI

extension UISerial {
    /// Right-clicking empty space gives the folder's own menu in every view, and New Text File.
    @MainActor
    @Suite(.serialized) final class BackgroundMenuTests {
        let base = TestDirs.make("bgmenu")
        let folder: URL

        isolated deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            _ = NSApplication.shared
            folder = base.appendingPathComponent("Folder", isDirectory: true)
            let trash = base.appendingPathComponent("Trash", isDirectory: true)
            for d in [folder, trash, folder.appendingPathComponent("Sub")] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: folder.appendingPathComponent("a.txt").path, contents: Data("a".utf8))
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            OperationCenter.shared = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: base.appendingPathComponent("journal"))), trash: { url in
                let dest = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
            FileOperationsUI.shared.install()
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        private func browser(_ mode: ViewMode) async -> (BrowserViewController, NSWindow) {
            let vc = BrowserViewController(location: .folder(folder))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            window.setContentSize(NSSize(width: 900, height: 600))
            vc.state.updatePresentation { $0.mode = mode }
            await wait { vc.state.loadState == .complete && vc.state.snapshot.items.count == 2 }
            window.layoutIfNeeded()
            return (vc, window)
        }

        private func titles(_ menu: NSMenu?) -> [String] { (menu?.items ?? []).filter { !$0.isSeparatorItem }.map(\.title) }
        private static let folderMenu = ["New Folder", "New Text File", "Paste", "Show Hidden Files", "Sort By", "Show View Options"]

        @Test func emptySpaceGivesTheFolderMenuWhateverIsSelected() async {
            let (vc, _) = await browser(.list)
            defer { vc.state.invalidate() }
            #expect(titles(vc.contentMenu(clicked: nil)) == Self.folderMenu)
            // With something selected it's still the folder's menu, not the selection's.
            let item = vc.state.snapshot.items.first { $0.name == "a.txt" }!
            vc.state.setSelection([item.id], anchor: item.id)
            #expect(titles(vc.contentMenu(clicked: nil)) == Self.folderMenu)
            // On the item itself: the item's menu.
            #expect(titles(vc.contentMenu(clicked: item.id)).first == "Open")
            // Its commands act on this browser wherever the keyboard focus is.
            #expect(vc.contentMenu(clicked: nil)?.items.filter { $0.action != nil && !$0.hasSubmenu }.allSatisfy { $0.target === vc } == true)
        }

        /// The same menu comes up in every view, from the space the view itself doesn't cover.
        @Test(arguments: ViewMode.allCases) func everyViewOffersItOnEmptySpace(_ mode: ViewMode) async throws {
            let (vc, window) = await browser(mode)
            defer { vc.state.invalidate() }
            // A right-click near the bottom right of the content area, far from the two items.
            let content = try #require(vc.content?.view.superview as? BackgroundMenuView)
            let spot = content.convert(NSPoint(x: content.bounds.maxX - 30, y: content.bounds.minY + 30), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: spot, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            // What AppKit does: ask the view under the pointer, then its ancestors, for a menu.
            var view = window.contentView?.hitTest(window.contentView!.convert(spot, from: nil))
            var menu: NSMenu?
            while let v = view, menu == nil {
                menu = v.menu(for: event)
                view = v.superview
            }
            #expect(titles(menu) == Self.folderMenu, "\(mode): \(titles(menu))")
        }

        @Test func newTextFileIsCreatedSelectedAndReadyToRename() async {
            let (vc, _) = await browser(.list)
            defer { vc.state.invalidate() }
            vc.newTextFile(nil)
            await wait { FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("untitled.txt").path) }
            await wait { vc.state.selectedItems.map(\.name) == ["untitled.txt"] }
            #expect(vc.state.selectedItems.map(\.name) == ["untitled.txt"])
            await wait { !vc.renameField.isHidden && vc.renameField.superview != nil }
            #expect(vc.renameField.stringValue == "untitled.txt")
            vc.endRename(commit: false)
            // Again: the name is taken, so it gets a number.
            vc.newTextFile(nil)
            await wait { FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("untitled 2.txt").path) }
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("untitled 2.txt").path))
        }

        @Test func notOfferedWhereThereIsNoFolder() async {
            let vc = BrowserViewController(location: .computer)
            defer { vc.state.invalidate() }
            _ = vc.view
            let item = NSMenuItem(title: "", action: #selector(BrowserViewController.newTextFile(_:)), keyEquivalent: "")
            #expect(!vc.validateMenuItem(item))
        }
    }
}
