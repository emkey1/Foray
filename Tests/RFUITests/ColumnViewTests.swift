import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

extension UISerial {
    @MainActor
    @Suite(.serialized) final class ColumnViewTests {
        let base = TestDirs.make("columns")
        let projects: URL

        deinit { try? FileManager.default.removeItem(at: base) }

        init() throws {
            projects = base.appendingPathComponent("Projects", isDirectory: true)
            for path in ["b.txt", "a.txt", "sub/x.txt", "sub/y.txt", "zdir/z.txt"] {
                let url = projects.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            }
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        @Test func browsingWithColumns() async throws {
            let browser = BrowserViewController(location: .folder(projects))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = browser
            window.setContentSize(NSSize(width: 1100, height: 500))
            let state = browser.state
            defer { state.invalidate() }
            await wait { state.loadState == .complete && state.snapshot.items.count == 4 }
            let heightBefore = window.frame.height
            state.updatePresentation { $0.mode = .column }
            window.layoutIfNeeded()
            #expect(window.frame.height == heightBefore, "switching to column view resized the window: \(heightBefore) → \(window.frame.height)")
            let columns = try #require(browser.children.compactMap { $0 as? ColumnContentViewController }.first)
            #expect(columns.columnSummaries.map(\.items) == [["a.txt", "b.txt", "sub", "zdir"]])

            // Selecting a folder peeks its contents in the next column.
            let sub = try #require(state.snapshot.items.first { $0.name == "sub" })
            state.setSelection([sub.id], anchor: sub.id)
            browser.content?.showSelection([sub.id], reveal: sub.id)
            await wait { columns.columnSummaries.last?.items == ["x.txt", "y.txt"] }
            #expect(columns.columnSummaries.map(\.role) == ["current", "peek"])

            // → goes into it: the location changes and the parent column highlights the path.
            columns.moveRightFromCurrent()
            await wait { state.location == .folder(self.projects.appendingPathComponent("sub")) && state.selectedItems.map(\.name) == ["x.txt"] }
            #expect(columns.columnSummaries.map(\.role).prefix(2) == ["ancestor", "current"])
            #expect(columns.columnSummaries[0].items == ["a.txt", "b.txt", "sub", "zdir"])
            #expect(columns.isShowingPreview)            // a file is selected: preview column

            // A sort change applies to every column.
            state.updateArrangement { $0.setPrimary(.name) }   // name descending
            await wait { columns.columnSummaries.first?.items.first == "zdir" && columns.columnSummaries[1].items.first == "y.txt" }
            #expect(columns.columnSummaries[0].items == ["zdir", "sub", "b.txt", "a.txt"])
            #expect(columns.columnSummaries[1].items == ["y.txt", "x.txt"])

            if let rep = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
                window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-columns.png"))
            }

            // ← goes back out with the folder selected (peeked again).
            columns.moveLeftFromCurrent()
            await wait { state.location == .folder(self.projects) && state.selectedItems.map(\.name) == ["sub"] }
            #expect(state.selectedItems.map(\.name) == ["sub"])
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class GalleryViewTests {
        let base = TestDirs.make("gallery")

        deinit { try? FileManager.default.removeItem(at: base) }

        @Test func galleryShowsTheSelectionAndKeepsTheOrder() async throws {
            let folder = base.appendingPathComponent("Pics", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, size) in [("c.txt", 30), ("a.txt", 10), ("b.txt", 20)] {
                FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(repeating: 65, count: size))
            }
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let browser = BrowserViewController(location: .folder(folder))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = browser
            window.setContentSize(NSSize(width: 1000, height: 600))
            let state = browser.state
            defer { state.invalidate() }
            let deadline = Date().addingTimeInterval(15)
            while !(state.loadState == .complete && state.snapshot.items.count == 3) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            state.updateArrangement { $0.setPrimary(.size) }   // largest first
            while state.snapshot.items.first?.name != "c.txt" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

            let height = window.frame.height
            state.updatePresentation { $0.mode = .gallery }
            window.layoutIfNeeded()
            #expect(window.frame.height == height)
            #expect(browser.children.contains { $0 is GalleryContentViewController })
            // Nothing was selected: the gallery selects the first item (in the shared order).
            while state.selection.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(state.selectedItems.map(\.name) == ["c.txt"])
            #expect(state.snapshot.items.map(\.name) == ["c.txt", "b.txt", "a.txt"])
        }
    }
}
