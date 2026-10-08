import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFUI

extension UISerial {
    /// The Trash location with private Trash folders (never the real Trash).
    @MainActor
    @Suite(.serialized) final class TrashUITests {
        let base = TestDirs.make("trashui")
        let work: URL, homeTrash: URL, volumeTrash: URL

        init() throws {
            work = base.appendingPathComponent("Work", isDirectory: true)
            homeTrash = base.appendingPathComponent(".Trash", isDirectory: true)
            volumeTrash = TrashFolders.folder(onVolume: base.appendingPathComponent("Vol"))
            for d in [work, homeTrash, volumeTrash] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            TrashFolders.overrideForTesting([homeTrash, volumeTrash])
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let t = homeTrash
            OperationCenter.shared = OperationCenter(
                journal: OperationJournal(store: AppSupportStore(directory: base.appendingPathComponent("journal"))),
                trash: { url in
                    let dest = t.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: dest)
                    return dest
                })
            FileOperationsUI.shared.install()
        }

        isolated deinit {
            TrashFolders.overrideForTesting(nil)
            try? FileManager.default.removeItem(at: base)
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        private func browser(_ location: Location) async -> (BrowserViewController, NSWindow) {
            let vc = BrowserViewController(location: location)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            await wait { vc.state.loadState == .complete }
            return (vc, window)
        }

        @Test func trashThenPutBackFromTheTrashLocation() async throws {
            FileManager.default.createFile(atPath: work.appendingPathComponent("doc.txt").path, contents: Data("hi".utf8))
            FileManager.default.createFile(atPath: volumeTrash.appendingPathComponent("other.txt").path, contents: nil)
            let (folder, w1) = await browser(.folder(work))
            folder.state.select(names: ["doc.txt"])
            await wait { !folder.state.selectedItems.isEmpty }
            let trashItem = NSMenuItem(title: "", action: #selector(BrowserViewController.moveToTrash(_:)), keyEquivalent: "")
            #expect(folder.validateMenuItem(trashItem) && trashItem.title == "Move to Trash")
            folder.moveToTrash(nil)
            await wait { !FileManager.default.fileExists(atPath: self.work.appendingPathComponent("doc.txt").path) }

            // Both Trashes show together.
            let (trash, w2) = await browser(.trash)
            await wait { trash.state.snapshot.items.count == 2 }
            #expect(Set(trash.state.snapshot.items.map(\.name)) == ["doc.txt", "other.txt"])
            #expect(LocationInfo.displayName(.trash) == "Trash")

            trash.state.select(names: ["doc.txt"])
            await wait { !trash.state.selectedItems.isEmpty }
            #expect(trash.validateMenuItem(trashItem) && trashItem.title == "Put Back")
            let menu = try #require(trash.contentMenu(clicked: trash.state.selectedItems.first?.id))
            #expect(menu.items.contains { $0.title == "Put Back" })
            #expect(!menu.items.contains { $0.title == "Move to Trash" })

            trash.moveToTrash(nil)   // ⌘⌫ in the Trash puts back
            await wait { FileManager.default.fileExists(atPath: self.work.appendingPathComponent("doc.txt").path) }
            #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("doc.txt").path))
            await wait { trash.state.snapshot.items.count == 1 }
            #expect(trash.state.snapshot.items.map(\.name) == ["other.txt"])

            trash.state.setSelection([], anchor: nil)
            let emptyMenu = try #require(trash.contentMenu(clicked: nil))
            #expect(emptyMenu.items.map(\.title) == ["Empty Trash…"])
            folder.state.invalidate()
            trash.state.invalidate()
            _ = (w1, w2)
        }

        @Test func sidebarHasTheTrash() async throws {
            let sidebar = SidebarViewController()
            _ = sidebar.view
            sidebar.reload()
            #expect(sidebar.sectionsForTesting.flatMap(\.children).contains { $0.location == .trash })
        }
    }
}
