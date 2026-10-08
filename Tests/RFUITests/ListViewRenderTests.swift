import AppKit
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

@MainActor
@Suite(.serialized) struct ListViewRenderTests {
    @Test func listViewShowsRows() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rf-render-\(UUID().uuidString)")
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
        let deadline = Date().addingTimeInterval(5)
        while browser.state.snapshot.items.count < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        browser.state.updatePresentation { $0.mode = .list }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()

        let list = try #require(browser.children.first as? ListContentViewController)
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
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rf-render-search-\(UUID().uuidString)")
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
        let deadline = Date().addingTimeInterval(5)
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
