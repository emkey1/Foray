import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

extension UISerial {
    /// Control-click opens the same menus as a right-click, in every view (it used to do nothing
    /// in list and column view, and on items in icon and gallery view).
    @MainActor
    @Suite(.serialized) final class ControlClickTests {
        let base = TestDirs.make("ctrlclick")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        private func window(_ mode: ViewMode, files: Int) async throws -> BrowserWindowController {
            _ = NSApplication.shared
            let folder = base.appendingPathComponent("F-\(mode.rawValue)-\(files)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<files { FileManager.default.createFile(atPath: folder.appendingPathComponent("file \(i).txt").path, contents: Data("x".utf8)) }
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store-\(mode.rawValue)-\(files)")))
            let c = BrowserWindowController(location: .folder(folder))
            c.window?.setContentSize(NSSize(width: 1000, height: 640))
            c.showWindow(nil)
            c.browser.state.updatePresentation { $0.mode = mode }
            await wait { c.browser.state.loadState == .complete && c.browser.state.snapshot.items.count == files }
            c.window?.layoutIfNeeded()
            c.window?.displayIfNeeded()
            return c
        }

        private func click(_ flags: NSEvent.ModifierFlags, at point: NSPoint, in window: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        private func titles(_ menu: NSMenu?) -> [String] { (menu?.items ?? []).filter { !$0.isSeparatorItem }.map(\.title) }

        @Test(arguments: ViewMode.allCases) func onEmptySpaceItOpensTheFolderMenu(_ mode: ViewMode) async throws {
            let c = try await window(mode, files: 2)
            let window = try #require(c.window)
            defer { window.close() }
            let content = try #require(c.browser.content?.view.superview)
            // Low down and far right: clear of the two items in every view.
            let spot = content.convert(NSPoint(x: content.bounds.maxX - 30, y: content.bounds.minY + 40), to: nil)
            let found = ContextClick.target(for: click(.control, at: spot, in: window))
            #expect(titles(found?.0).prefix(3) == ["New Folder", "New Text File", "Paste"], "\(mode): \(titles(found?.0))")
        }

        @Test(arguments: ViewMode.allCases) func onAnItemItOpensThatItemsMenu(_ mode: ViewMode) async throws {
            let c = try await window(mode, files: 3)
            let window = try #require(c.window)
            defer { window.close() }
            let item = try #require(c.browser.state.snapshot.items.first { $0.name == "file 1.txt" })
            c.browser.state.setSelection([], anchor: nil)
            // Where the item is: its name in most views; its thumbnail in the gallery's strip.
            var spot: NSPoint
            if mode == .gallery {
                func find(_ v: NSView) -> NSCollectionView? { (v as? NSCollectionView) ?? v.subviews.lazy.compactMap(find).first }
                let contentView = try #require(c.browser.content?.view)
                let strip = try #require(find(contentView))
                let index = try #require(c.browser.state.snapshot.items.firstIndex { $0.id == item.id })
                let frame = try #require(strip.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
                spot = strip.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            } else {
                await wait { c.browser.content?.nameFrameInWindow(for: item.id) != nil }
                let frame = try #require(c.browser.content?.nameFrameInWindow(for: item.id))
                spot = NSPoint(x: frame.minX + 6, y: frame.midY)
            }
            let found = ContextClick.target(for: click(.control, at: spot, in: window))
            #expect(titles(found?.0).first == "Open", "\(mode): \(titles(found?.0))")
            // And, as with a right-click, the item under the pointer becomes the selection.
            #expect(c.browser.state.selectedItems.map(\.name) == ["file 1.txt"], "\(mode)")
        }

        @Test func otherClicksAreLeftAlone() async throws {
            let c = try await window(.list, files: 2)
            let window = try #require(c.window)
            defer { window.close() }
            let content = try #require(c.browser.content?.view.superview)
            let spot = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.minY + 40), to: nil)
            #expect(ContextClick.target(for: click([], at: spot, in: window)) == nil)                       // a plain click
            #expect(ContextClick.target(for: click([.control, .command], at: spot, in: window)) == nil)     // other shortcuts
            #expect(ContextClick.target(for: click([.control, .shift], at: spot, in: window)) == nil)
            // Outside the file views (the toolbar area at the very top): not ours to handle.
            let top = NSPoint(x: window.frame.width / 2, y: window.frame.height - 8)
            #expect(ContextClick.target(for: click(.control, at: top, in: window)) == nil)
        }

        @Test func theSidebarHasItsMenusToo() async throws {
            let c = try await window(.list, files: 2)
            let window = try #require(c.window)
            defer { window.close() }
            let root = try #require(window.contentView)
            // Find the sidebar's list and Control-click its second row (the first favorite after Recents).
            func find(_ v: NSView) -> SidebarOutlineView? { (v as? SidebarOutlineView) ?? v.subviews.lazy.compactMap(find).first }
            let sidebar = try #require(find(root))
            let row = (0..<sidebar.numberOfRows).first { (sidebar.item(atRow: $0) as? SidebarViewController.Node)?.favoriteIndex != nil }
            let rect = sidebar.rect(ofRow: try #require(row))
            let spot = sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let found = ContextClick.target(for: click(.control, at: spot, in: window))
            #expect(found != nil && !titles(found?.0).isEmpty)
        }
    }
}
