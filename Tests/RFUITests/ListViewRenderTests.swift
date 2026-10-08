import AppKit
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

@MainActor
@Suite(.serialized) struct ListViewRenderTests {
    @Test func listViewShowsRows() async throws {
        let base = TestDirs.make("render")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["alpha.txt", "beta.pdf", "gamma.jpg"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))

        let browser = BrowserViewController(location: .folder(folder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 800, height: 500))
        let deadline = Date().addingTimeInterval(15)
        while browser.state.snapshot.items.count < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        browser.state.updatePresentation { $0.mode = .list }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()

        let list = try #require(browser.children.compactMap { $0 as? ListContentViewController }.first)
        let table = try #require(list.firstResponderView as? NSTableView)
        let scroll = try #require(table.enclosingScrollView)
        print("RENDER list.view=\(list.view.frame) scroll=\(scroll.frame) table=\(table.frame) rows=\(table.numberOfRows) cols=\(table.tableColumns.count)")
        #expect(table.numberOfRows == 3)
        #expect(scroll.frame.height > 100, "scroll view collapsed: \(scroll.frame)")

        if let rep = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-list-render.png"))
        }
        browser.state.invalidate()
    }
}

@MainActor
@Suite(.serialized) struct SearchRenderTests {
    @Test func searchResultsRender() async throws {
        let base = TestDirs.make("render-search")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Projects")
        for dir in ["app/src", "docs"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for path in ["app/src/report.swift", "docs/report.pdf", "report.md", "other.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(path).path, contents: Data("x".utf8))
        }
        AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
        let browser = BrowserViewController(location: .folder(folder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 900, height: 500))
        browser.state.search("report")
        let deadline = Date().addingTimeInterval(15)
        while !(browser.state.loadState == .complete && browser.state.snapshot.items.count == 3) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(browser.state.snapshot.items.count == 3)
        if let rep = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-search-render.png"))
        }
        browser.state.invalidate()
    }
}

@MainActor
@Suite(.serialized) struct WindowTests {
    /// Regression: windows preferred tabs, so New Window merged into the existing window.
    @Test func newWindowIsSeparateAndNewTabIsATab() async throws {
        _ = NSApplication.shared
        let store = TestDirs.make("win")
        defer { try? FileManager.default.removeItem(at: store) }
        AppModel.shared = AppModel(store: AppSupportStore(directory: store))
        let manager = WindowManager()
        let home = Location.folder(FileManager.default.temporaryDirectory)
        manager.openWindow(home)
        manager.openWindow(home)
        let windows = manager.controllersForTesting.compactMap(\.window)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { ($0.tabbedWindows?.count ?? 1) == 1 })

        manager.openTab(home, nextTo: manager.controllersForTesting[0])
        let first = try #require(manager.controllersForTesting[0].window)
        #expect(first.tabbedWindows?.count == 2)
        for c in manager.controllersForTesting { c.window?.close() }
    }
}

@MainActor
@Suite(.serialized) struct DisclosureTests {
    @Test func expandingAFolderShowsItsContentsInPlace() async throws {
        let base = TestDirs.make("disclosure")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        for (path, size) in [("app/b-small.txt", 1), ("app/a-big.txt", 5000), ("app/src/main.swift", 10), ("readme.md", 3)] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(path).path, contents: Data(repeating: 65, count: size))
        }
        AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
        let browser = BrowserViewController(location: .folder(folder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 800, height: 300))
        func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let state = browser.state
        await wait { state.snapshot.items.count == 2 }
        state.updatePresentation { $0.mode = .list }
        let list = try #require(browser.children.compactMap { $0 as? ListContentViewController }.first)
        let outline = try #require(list.firstResponderView as? NSOutlineView)
        func names() -> [String] {
            (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? ListContentViewController.Node)?.item?.name }
        }

        let app = try #require(state.snapshot.items.first { $0.name == "app" })
        let appNode = try #require(outline.item(atRow: 0))
        outline.expandItem(appNode)
        await wait { state.children[app.id]?.items.count == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(names() == ["app", "a-big.txt", "b-small.txt", "src", "readme.md"])
        #expect(outline.level(forRow: 1) == 1)

        state.updateArrangement { $0.setPrimary(.size) }          // children follow the sort
        await wait { state.children[app.id]?.items.map(\.name) == ["a-big.txt", "b-small.txt", "src"] }
        #expect(state.children[app.id]?.items.map(\.name) == ["a-big.txt", "b-small.txt", "src"])

        state.updatePresentation { $0.mode = .icon }              // expansion survives a view switch
        state.updatePresentation { $0.mode = .list }
        let list2 = try #require(browser.children.compactMap { $0 as? ListContentViewController }.first)
        let outline2 = try #require(list2.firstResponderView as? NSOutlineView)
        #expect(outline2.numberOfRows == 5)

        if let rep = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-disclosure.png"))
        }

        // Sorted by size now: files first, folders (no size) last.
        let appRow = (0..<outline2.numberOfRows).first { (outline2.item(atRow: $0) as? ListContentViewController.Node)?.item?.name == "app" }
        outline2.collapseItem(outline2.item(atRow: try #require(appRow)))
        #expect(!state.expanded.contains(app.id))
        #expect(state.children[app.id] == nil)
        #expect(outline2.numberOfRows == 2)
        state.invalidate()
    }
}
