import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFUI

extension UISerial {
    @MainActor
    @Suite(.serialized) final class AliasUITests {
        let base = TestDirs.make("aliasui")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        @Test func folderAliasesOpenHereAndShowOriginal() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let work = base.appendingPathComponent("Work", isDirectory: true)
            let target = base.appendingPathComponent("Target", isDirectory: true)
            for d in [work, target] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: target.appendingPathComponent("inside.txt").path, contents: nil)
            try Aliases.make(to: target, at: work.appendingPathComponent("Target alias"))

            let vc = BrowserViewController(location: .folder(work))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            defer { vc.state.invalidate() }
            await wait { vc.state.loadState == .complete && !vc.state.snapshot.items.isEmpty }
            vc.state.select(names: ["Target alias"])
            await wait { !vc.state.selectedItems.isEmpty }
            #expect(vc.state.selectedItems.first?.flags.contains(.alias) == true)

            let r = NSMenuItem(title: "", action: #selector(BrowserViewController.showInEnclosingFolder(_:)), keyEquivalent: "r")
            #expect(vc.validateMenuItem(r) && r.title == "Show Original")
            let menu = try #require(vc.contentMenu(clicked: vc.state.selectedItems.first?.id))
            #expect(menu.items.contains { $0.title == "Show Original" })
            #expect(menu.items.contains { $0.title == "Make Alias" })
            #expect(menu.items.contains { $0.title == "Compress “Target alias”" })

            // Opening the alias goes into the folder here (not to Finder).
            vc.openSelection(nil)
            await wait { vc.state.location.folderURL?.lastPathComponent == "Target" }
            #expect(vc.state.location.folderURL?.lastPathComponent == "Target")

            // Show Original: back to Work, then ⌘R selects the original in its folder.
            vc.state.goBack()
            await wait { vc.state.location.folderURL?.lastPathComponent == "Work" && !vc.state.snapshot.items.isEmpty }
            vc.state.select(names: ["Target alias"])
            await wait { !vc.state.selectedItems.isEmpty }
            vc.showInEnclosingFolder(nil)
            await wait { vc.state.selectedItems.first?.name == "Target" }
            #expect(vc.state.location.folderURL?.standardizedFileURL.resolvingSymlinksInPath() == base.resolvingSymlinksInPath())
            #expect(vc.state.selectedItems.map(\.name) == ["Target"])
        }
    }
}
