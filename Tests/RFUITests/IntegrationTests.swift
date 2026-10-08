import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

extension UISerial {
    @MainActor
    @Suite(.serialized) final class IntegrationTests {
        let base = TestDirs.make("integration")
        isolated deinit {
            SpringLoading.isDragging = { NSEvent.pressedMouseButtons & 1 != 0 }
            SpringLoading.delay = 0.8
            try? FileManager.default.removeItem(at: base)
        }

        @Test func realfinderLinks() throws {
            let folder = base.appendingPathComponent("Proj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("a b.txt").path, contents: nil)
            let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }

            let open = try #require(AppIntegration.location(for: URL(string: "realfinder://open?path=\(enc(folder.path))")!))
            #expect(open.0 == .folder(folder) || open.0.folderURL?.path == folder.path)
            let file = try #require(AppIntegration.location(for: URL(string: "realfinder://open?path=\(enc(folder.path + "/a b.txt"))")!))
            #expect(file.0.folderURL?.path == folder.path && file.select == ["a b.txt"])
            let search = try #require(AppIntegration.location(for: URL(string: "realfinder://search?q=\(enc("report kind:pdf"))&in=\(enc(folder.path))")!))
            #expect(search.0.searchQuery?.text == "report kind:pdf")
            #expect(search.0.searchQuery?.scope.folderURL?.path == folder.path)
            #expect(AppIntegration.location(for: URL(string: "realfinder://search?q=x")!)?.0.searchQuery?.scope == .thisMac)
            #expect(AppIntegration.location(for: URL(string: "realfinder://open?path=/no/such/place")!) == nil)
            #expect(AppIntegration.location(for: URL(string: "https://example.com")!) == nil)
        }

        @Test func recentFoldersAndTheDockMenu() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let a = base.appendingPathComponent("A", isDirectory: true), b = base.appendingPathComponent("B", isDirectory: true)
            for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let state = BrowserState(location: .folder(a))
            defer { state.invalidate() }
            state.navigate(to: .folder(b))
            state.navigate(to: .folder(a))
            #expect(AppModel.shared.recentFolders.prefix(2).map(\.lastPathComponent) == ["A", "B"])
            for i in 0..<12 {
                let d = base.appendingPathComponent("D\(i)", isDirectory: true)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                state.navigate(to: .folder(d))
            }
            #expect(AppModel.shared.recentFolders.count == AppModel.recentFolderLimit)
            let dock = AppIntegration.dockMenu()
            #expect(dock.items.first?.title == "New RealFinder Window")
            #expect(dock.items.contains { $0.title == "D11" })
            let go = AppIntegration.recentFoldersMenuItem()
            MenuTarget.shared.menuNeedsUpdate(go.submenu!)
            #expect(go.submenu?.items.last?.title == "Clear Menu")
            AppModel.shared.clearRecentFolders()
            MenuTarget.shared.menuNeedsUpdate(go.submenu!)
            #expect(go.submenu?.items.map(\.title) == ["No Recent Folders"])
        }

        @Test func springLoadingOpensAfterAPause() async throws {
            SpringLoading.delay = 0.05
            var dragging = true
            SpringLoading.isDragging = { dragging }
            var opened: [String] = []
            let x = base.appendingPathComponent("X"), y = base.appendingPathComponent("Y")
            SpringLoading.hover(x) { opened.append($0.lastPathComponent) }
            SpringLoading.hover(y) { opened.append($0.lastPathComponent) }   // moved on: X never opens
            try await Task.sleep(for: .milliseconds(200))
            #expect(opened == ["Y"])
            dragging = false
            SpringLoading.hover(x) { opened.append($0.lastPathComponent) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(opened == ["Y"])   // the drag ended
            SpringLoading.hover(nil)
        }

        @Test func servicesGetTheSelectedFiles() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store2")))
            let w = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: w.appendingPathComponent("s.txt").path, contents: nil)
            let vc = BrowserViewController(location: .folder(w))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            defer { vc.state.invalidate() }
            let deadline = Date().addingTimeInterval(15)
            while vc.state.snapshot.items.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(vc.validRequestor(forSendType: .fileURL, returnType: nil) == nil)   // nothing selected
            vc.state.select(names: ["s.txt"])
            #expect(vc.validRequestor(forSendType: .fileURL, returnType: nil) as? BrowserViewController === vc)
            let pb = NSPasteboard(name: .init("rf-test-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            #expect(vc.writeSelection(to: pb, types: [.fileURL]))
            let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
            #expect(urls?.map(\.lastPathComponent) == ["s.txt"])
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class BatchRenameSheetTests {
        @Test func previewAndPairs() throws {
            func item(_ name: String, _ inode: UInt64) -> FileItem {
                FileItem(id: FileID(device: 1, inode: inode), url: URL(fileURLWithPath: "/tmp/x/\(name)"), name: name,
                         contentType: .jpeg, flags: [], size: 1)
            }
            let model = BatchRenameModel(items: [item("IMG_1.jpg", 1), item("IMG_2.jpg", 2)], existing: ["IMG_1.jpg", "IMG_2.jpg", "Trip 2.jpg"])
            #expect(!model.canRename)   // nothing changes yet
            model.rule.find = "IMG_"
            model.rule.replacement = "Trip "
            #expect(model.newNames == ["Trip 1.jpg", "Trip 2.jpg"])
            #expect(model.problems[1] != nil && !model.canRename)   // "Trip 2.jpg" is taken
            model.rule.replacement = "Beach "
            #expect(model.canRename)
            #expect(model.pairs.map(\.to.lastPathComponent) == ["Beach 1.jpg", "Beach 2.jpg"])

            let host = NSHostingView(rootView: BatchRenameView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 470)
            host.appearance = NSAppearance(named: .aqua)   // offscreen capture skips the window background
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-batchrename.png"))
            }
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class InspectorTests {
        let base = TestDirs.make("inspector")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func summarizesSeveralItems() {
            func item(_ name: String, _ inode: UInt64, size: Int64?, folder: Bool = false) -> FileItem {
                FileItem(id: FileID(device: 1, inode: inode), url: URL(fileURLWithPath: "/x/\(name)"), name: name,
                         contentType: folder ? .folder : .plainText, flags: folder ? [.directory] : [], size: size)
            }
            let items = [item("a.txt", 1, size: 100), item("b.txt", 2, size: 50), item("F", 3, size: nil, folder: true)]
            let s = SelectionSummary(items)
            #expect(s.count == 3 && s.folders == 1 && s.bytes == 150)
            #expect(s.kinds.first?.count == 2)
            #expect(SelectionSummary(items, folderSizes: [FileID(device: 1, inode: 3): 1000]).bytes == 1150)
        }

        @Test func followsTheSelection() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let w = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            for n in ["one.txt", "two.txt"] { FileManager.default.createFile(atPath: w.appendingPathComponent(n).path, contents: Data("x".utf8)) }
            let state = BrowserState(location: .folder(w))
            defer { state.invalidate() }
            let deadline = Date().addingTimeInterval(15)
            while state.snapshot.items.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let panel = InspectorPanel.shared
            panel.attach(state)
            state.select(names: ["one.txt"])
            #expect(panel.contentView is NSHostingView<InfoView>)
            state.select(names: ["one.txt", "two.txt"])
            #expect(panel.contentView is NSHostingView<SummaryView>)
            panel.orderOut(nil)
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class ToolbarTests {
        let base = TestDirs.make("toolbar")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func everyOptionalItemCanBeAdded() throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let wc = BrowserWindowController(location: .folder(base), pendingSearch: nil)
            defer { wc.browser.state.invalidate(); wc.window?.close() }
            let toolbar = try #require(wc.window?.toolbar)
            #expect(toolbar.allowsUserCustomization)
            let allowed = wc.toolbarAllowedItemIdentifiers(toolbar)
            let builtIn: Set<NSToolbarItem.Identifier> = [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space]
            for id in allowed where !builtIn.contains(id) {
                let item = wc.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
                #expect(item != nil, "\(id.rawValue)")
                #expect(item?.label.isEmpty == false, "\(id.rawValue)")
            }
            #expect(allowed.contains(.init("getInfo")) && allowed.contains(.init("tags")))
            // The Tags menu reflects the selection.
            let menu = NSMenu()
            wc.menuNeedsUpdate(menu)
            #expect(menu.items.first?.title == "Select items to tag them")
        }
    }
}
