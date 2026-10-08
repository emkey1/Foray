import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFUI

/// Nested in UISerial: these tests swap shared singletons (AppModel.shared, OperationCenter.shared),
/// so they must not run in parallel with each other.
extension UISerial {
    /// File commands through the real browser (offscreen window), with a private Trash.
    @MainActor
    @Suite(.serialized) final class FileCommandTests {
        let base = TestDirs.make("filecmd")
        let a: URL, b: URL, trash: URL

        deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            a = base.appendingPathComponent("A", isDirectory: true)
            b = base.appendingPathComponent("B", isDirectory: true)
            trash = base.appendingPathComponent("Trash", isDirectory: true)
            for d in [a, b, trash] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: a.appendingPathComponent("doc.txt").path, contents: Data("hello".utf8))
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let t = trash
            OperationCenter.shared = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: base.appendingPathComponent("journal"))), trash: { url in
                let dest = t.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
            FileOperationsUI.shared.install()
        }

        private func browser(_ folder: URL) async -> (BrowserViewController, NSWindow) {
            let vc = BrowserViewController(location: .folder(folder))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            window.setContentSize(NSSize(width: 800, height: 500))
            await wait { vc.state.loadState == .complete }
            return (vc, window)
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

        @Test func copyAndPasteIntoAnotherFolderSelectsTheResult() async {
            let (va, _) = await browser(a), (vb, _) = await browser(b)
            defer { va.state.invalidate(); vb.state.invalidate() }
            await wait { !va.state.snapshot.items.isEmpty }
            select(va, "doc.txt")
            va.copy(nil)
            vb.paste(nil)
            await wait { vb.state.selectedItems.map(\.name) == ["doc.txt"] }
            #expect(names(a) == ["doc.txt"] && names(b) == ["doc.txt"])
            #expect(vb.state.selectedItems.map(\.name) == ["doc.txt"])
        }

        @Test func cutAndPasteMoves() async {
            let (va, _) = await browser(a), (vb, _) = await browser(b)
            defer { va.state.invalidate(); vb.state.invalidate() }
            await wait { !va.state.snapshot.items.isEmpty }
            select(va, "doc.txt")
            va.cut(nil)
            #expect(FileClipboard.isCut(a.appendingPathComponent("doc.txt")))
            vb.paste(nil)
            await wait { self.names(a).isEmpty && va.state.snapshot.items.isEmpty }
            #expect(names(b) == ["doc.txt"])
            #expect(va.state.snapshot.items.isEmpty)        // source tab refreshed right away
            #expect(!FileClipboard.isCut(b.appendingPathComponent("doc.txt")))
        }

        @Test func duplicateThenUndo() async {
            let (va, _) = await browser(a)
            defer { va.state.invalidate() }
            await wait { !va.state.snapshot.items.isEmpty }
            select(va, "doc.txt")
            va.duplicate(nil)
            await wait { self.names(self.a).count == 2 && va.state.selectedItems.map(\.name) == ["doc copy.txt"] }
            #expect(va.state.selectedItems.map(\.name) == ["doc copy.txt"])
            OperationCenter.shared.undoManager.undo()
            await wait { self.names(self.a) == ["doc.txt"] }
            #expect(names(a) == ["doc.txt"])
        }

        @Test func newFolderStartsRenamingAndReturnCommits() async {
            let (va, window) = await browser(a)
            defer { va.state.invalidate() }
            _ = window
            va.newFolder(nil)
            await wait { !va.renameField.isHidden }
            #expect(!va.renameField.isHidden)
            #expect(va.renameField.stringValue == "untitled folder")
            va.renameField.stringValue = "Invoices"
            va.endRename(commit: true)
            await wait { self.names(self.a).contains("Invoices") }
            #expect(names(a) == ["doc.txt", "Invoices"])
        }

        @Test func renameSelectionInPlace() async {
            let (va, _) = await browser(a)
            defer { va.state.invalidate() }
            await wait { !va.state.snapshot.items.isEmpty }
            select(va, "doc.txt")
            va.renameSelection(nil)
            #expect(!va.renameField.isHidden && va.renameField.stringValue == "doc.txt")
            va.renameField.stringValue = "letter.txt"
            va.endRename(commit: true)
            await wait { self.names(self.a) == ["letter.txt"] }
            await wait { va.state.selectedItems.map(\.name) == ["letter.txt"] }
            #expect(va.state.selectedItems.map(\.name) == ["letter.txt"])
        }

        @Test func trashAndUndoPutsItBack() async {
            let (va, _) = await browser(a)
            defer { va.state.invalidate() }
            await wait { !va.state.snapshot.items.isEmpty }
            select(va, "doc.txt")
            va.moveToTrash(nil)
            await wait { self.names(self.a).isEmpty }
            #expect(names(trash).count == 1)
            OperationCenter.shared.undoManager.undo()
            await wait { self.names(self.a) == ["doc.txt"] }
            #expect(names(a) == ["doc.txt"] && names(trash).isEmpty)
        }
    }
}
