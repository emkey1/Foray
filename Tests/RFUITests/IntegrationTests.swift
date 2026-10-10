import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
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

        @Test func forayLinks() throws {
            let folder = base.appendingPathComponent("Proj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("a b.txt").path, contents: nil)
            let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }

            let open = try #require(AppIntegration.location(for: URL(string: "foray://open?path=\(enc(folder.path))")!))
            #expect(open.0 == .folder(folder) || open.0.folderURL?.path == folder.path)
            let file = try #require(AppIntegration.location(for: URL(string: "foray://open?path=\(enc(folder.path + "/a b.txt"))")!))
            #expect(file.0.folderURL?.path == folder.path && file.select == ["a b.txt"])
            let search = try #require(AppIntegration.location(for: URL(string: "foray://search?q=\(enc("report kind:pdf"))&in=\(enc(folder.path))")!))
            #expect(search.0.searchQuery?.text == "report kind:pdf")
            #expect(search.0.searchQuery?.scope.folderURL?.path == folder.path)
            #expect(AppIntegration.location(for: URL(string: "foray://search?q=x")!)?.0.searchQuery?.scope == .thisMac)
            #expect(AppIntegration.location(for: URL(string: "foray://open?path=/no/such/place")!) == nil)
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
            #expect(dock.items.first?.title == "New Foray Window")
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

extension UISerial {
    @MainActor
    @Suite(.serialized) final class FreeArrangementTests {
        let base = TestDirs.make("freearrange")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func gridPlacementSnappingAndDrops() {
            let grid = FreeArrangement(cellSize: NSSize(width: 100, height: 100), spacing: 10, width: 360)
            #expect(grid.columns == 3)
            let frames = grid.frames(for: ["a", "b", "c", "d"], saved: ["b": CGPoint(x: 14, y: 10)])
            #expect(frames[1].origin == CGPoint(x: 14, y: 10))     // b keeps its spot
            #expect(frames[0].origin == CGPoint(x: 124, y: 10))    // a skips the taken first cell
            #expect(frames[3].origin == CGPoint(x: 14, y: 120))    // wraps to the next row
            let snapped = grid.snapped(["x": CGPoint(x: 130, y: 15), "y": CGPoint(x: 128, y: 12)])
            #expect(Set(snapped.values.map(\.x)) == [124, 234] || Set(snapped.values.map(\.x)) == [14, 124])
            #expect(Set(snapped.values.map { "\($0)" }).count == 2)   // never the same cell
            #expect(grid.dropPositions(["n"], at: NSPoint(x: 200, y: 200))["n"] == CGPoint(x: 150, y: 150))
        }

        @Test func sortByNoneKeepsArrangementAndDragsMoveIcons() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let w = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            for n in ["a.txt", "b.txt", "c.txt"] { FileManager.default.createFile(atPath: w.appendingPathComponent(n).path, contents: nil) }
            let vc = BrowserViewController(location: .folder(w))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            defer { vc.state.invalidate() }
            vc.state.updatePresentation { $0.mode = .icon }
            let deadline = Date().addingTimeInterval(15)
            while vc.state.snapshot.items.count < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(100))
            let icons = try #require(vc.content as? IconContentViewController)
            let before = icons.currentPositions()

            let none = NSMenuItem(title: "None", action: #selector(BrowserViewController.sortBy(_:)), keyEquivalent: "")
            none.tag = SortKey.allCases.firstIndex(of: .manual)!
            vc.sortBy(none)
            while !icons.isFree && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(icons.isFree)
            #expect(AppModel.shared.iconPositions(in: w) == before)   // nothing jumped

            // Drag a.txt 300 points right.
            let a = try #require(vc.state.snapshot.items.firstIndex { $0.name == "a.txt" })
            let start = icons.framesForTesting[a].origin
            icons.beginDragForTesting([a], at: NSPoint(x: 0, y: 0))
            icons.moveDragged(to: NSPoint(x: 300, y: 40))
            #expect(AppModel.shared.iconPositions(in: w)["a.txt"] == CGPoint(x: start.x + 300, y: start.y + 40))
            let i = try #require(vc.state.snapshot.items.firstIndex { $0.name == "a.txt" })
            #expect(icons.framesForTesting[i].origin == CGPoint(x: start.x + 300, y: start.y + 40))

            let clean = NSMenuItem(title: "", action: #selector(BrowserViewController.cleanUp(_:)), keyEquivalent: "")
            #expect(vc.validateMenuItem(clean))
            vc.cleanUp(nil)
            let cleaned = AppModel.shared.iconPositions(in: w)
            #expect(Set(cleaned.values.map { "\($0)" }).count == 3)
            #expect(cleaned.values.allSatisfy { icons.arrangementGrid.snapped(["t": $0])["t"] == $0 })   // all on the grid
        }
    }
}

extension UISerial {
    @MainActor
    @Suite final class FreeArrangementScaleTests {
        @Test func placesTenThousandIconsQuickly() {
            let grid = FreeArrangement(cellSize: NSSize(width: 100, height: 112), spacing: 12, width: 1200)
            let names = (0..<10_000).map { "f\($0)" }
            var saved: [String: CGPoint] = [:]
            for i in stride(from: 0, to: 10_000, by: 7) { saved[names[i]] = grid.cellOrigin(i * 3) }
            let start = Date()
            let frames = grid.frames(for: names, saved: saved)
            #expect(Date().timeIntervalSince(start) < 0.5)
            #expect(Set(frames.map { "\($0.origin)" }).count == 10_000)   // no two on the same spot
        }
    }
}

@MainActor
@Suite struct LegacyMigrationTests {
    @Test func adoptsRealFinderPreferencesOnce() throws {
        let suite = "rf-test-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The old app's domain can't be faked without touching real preferences; check the
        // one-time flag and that existing values are never overwritten.
        defaults.set("mine", forKey: "ReturnOpens")
        LegacyMigration.run(defaults: defaults)
        #expect(defaults.bool(forKey: LegacyMigration.doneKey))
        #expect(defaults.string(forKey: "ReturnOpens") == "mine")
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class QuickActionUITests {
        let base = TestDirs.make("quickui")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func menuOffersActionsForImagesOnly() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let w = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            let png = w.appendingPathComponent("pic.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: png)
            FileManager.default.createFile(atPath: w.appendingPathComponent("notes.txt").path, contents: Data("x".utf8))
            let vc = BrowserViewController(location: .folder(w))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            defer { vc.state.invalidate() }
            let deadline = Date().addingTimeInterval(15)
            while vc.state.snapshot.items.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

            vc.state.select(names: ["pic.png"])
            let quick = try #require(vc.contentMenu(clicked: vc.state.selectedItems.first?.id)?.items.first { $0.title == "Quick Actions" })
            #expect(quick.submenu?.items.map(\.title) == ["Rotate Left", "Rotate Right", "Markup", "Create PDF"])
            #expect(vc.validateMenuItem(NSMenuItem(title: "", action: Commands.rotateRight, keyEquivalent: "")))

            vc.state.select(names: ["notes.txt"])
            #expect(vc.contentMenu(clicked: vc.state.selectedItems.first?.id)?.items.contains { $0.title == "Quick Actions" } == false)
            #expect(!vc.validateMenuItem(NSMenuItem(title: "", action: Commands.createPDF, keyEquivalent: "")))

            // Rotating from the browser goes through the engine (undoable).
            vc.state.select(names: ["pic.png"])
            vc.rotateRight(nil)
            while OperationCenter.shared.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(OperationCenter.shared.undoManager.undoActionName == "Rotate Right")
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class AccessUITests {
        let base = TestDirs.make("accessui")
        isolated deinit {
            BrowserViewController.openFile = { _ = NSWorkspace.shared.open($0) }
            try? FileManager.default.removeItem(at: base)
        }

        @Test func stationeryOpensACopy() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let w = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            let template = w.appendingPathComponent("Letter.txt")
            FileManager.default.createFile(atPath: template.path, contents: Data("Dear".utf8))
            #expect(Stationery.set(true, template) == 0)
            var opened: [URL] = []
            BrowserViewController.openFile = { opened.append($0) }
            let vc = BrowserViewController(location: .folder(w))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            defer { vc.state.invalidate() }
            let deadline = Date().addingTimeInterval(15)
            while vc.state.snapshot.items.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(vc.state.snapshot.items.first?.flags.contains(.stationery) == true)
            vc.state.select(names: ["Letter.txt"])
            vc.openSelection(nil)
            while opened.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(opened.map(\.lastPathComponent) == ["Letter copy.txt"])
            #expect(!Stationery.isSet(try #require(opened.first)))
            #expect(Stationery.isSet(template))   // the template stays a template
        }

        @Test func getInfoEditsTheAccessList() async throws {
            let w = base.appendingPathComponent("Shared", isDirectory: true)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            let staff = AccessEntry.make(.group, name: "staff", id: 20, level: .readOnly, isDirectory: true)
            #expect(AccessList.write(AccessList.text(for: [staff]), to: w) == 0)
            let model = InfoModel(item: try #require(DirectoryLoader.shared.stat(w)))
            let deadline = Date().addingTimeInterval(10)
            while model.info == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.accessEntries.map(\.name) == ["staff"])
            model.setLevel(.readWrite, at: 0)
            while AccessList.entries(AccessList.text(w)).first?.level != .readWrite && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(AccessList.entries(AccessList.text(w)).first?.level == .readWrite)
            while model.accessEntries.first?.level != .readWrite && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

            let host = NSHostingView(rootView: InfoView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 1100)
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-info-access.png"))
            }
            model.removeAccess(at: 0)
            while !AccessList.text(w).isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(AccessList.text(w).isEmpty)
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class FileViewerTests {
        let base = TestDirs.make("fileviewer")
        var stored: String?
        let realRead = FileViewerSetting.read, realWrite = FileViewerSetting.write

        init() {
            // Never the real system-wide preference.
            FileViewerSetting.read = { [unowned self] in self.stored }
            FileViewerSetting.write = { [unowned self] in self.stored = $0 }
        }

        isolated deinit {
            FileViewerSetting.read = realRead
            FileViewerSetting.write = realWrite
            try? FileManager.default.removeItem(at: base)
        }

        @Test func switchSetsAndClearsOnlyOurOwnValue() {
            #expect(!FileViewerSetting.isForay)
            FileViewerSetting.set(true)
            #expect(stored == FileViewerSetting.bundleID && FileViewerSetting.isForay)
            FileViewerSetting.set(false)
            #expect(stored == nil)
            stored = "com.cocoatech.PathFinder"
            FileViewerSetting.set(false)
            #expect(stored == "com.cocoatech.PathFinder")   // someone else's choice is left alone
            let model = SettingsPaneModel()
            #expect(!model.fileViewer)
            model.fileViewer = true
            #expect(stored == FileViewerSetting.bundleID)
        }

        @Test func showInFinderRevealsFilesSelected() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let w = base.appendingPathComponent("Docs", isDirectory: true)
            try FileManager.default.createDirectory(at: w.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            for n in ["a.txt", "b.txt"] { FileManager.default.createFile(atPath: w.appendingPathComponent(n).path, contents: nil) }
            let opened = WindowManager.shared.revealing([w.appendingPathComponent("a.txt"), w.appendingPathComponent("b.txt"), w.appendingPathComponent("Sub")])
            defer { for c in opened { c.browser.state.invalidate(); c.window?.close() } }
            #expect(opened.count == 2)   // one for Docs (both files selected), one for Sub
            let docs = try #require(opened.first)
            #expect(docs.browser.state.location.folderURL?.lastPathComponent == "Docs")
            let deadline = Date().addingTimeInterval(15)
            while docs.browser.state.selectedItems.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(Set(docs.browser.state.selectedItems.map(\.name)) == ["a.txt", "b.txt"])
            #expect(opened.last?.browser.state.location.folderURL?.lastPathComponent == "Sub")
        }
    }
}

extension UISerial {
    @MainActor
    @Suite final class SnapToGridTests {
        @Test func movedIconsLandOnFreeGridSpots() {
            let grid = FreeArrangement(cellSize: NSSize(width: 100, height: 100), spacing: 10, width: 360)
            let others = ["a": grid.cellOrigin(0), "b": grid.cellOrigin(1)]
            // Dropped almost on top of b: goes to the nearest free cell instead.
            let s = grid.snapped(["m": CGPoint(x: 130, y: 14)], others: others)
            #expect(s["m"] == grid.cellOrigin(2))
            let free = grid.snapped(["m": CGPoint(x: 20, y: 125)], others: others)
            #expect(free["m"] == grid.cellOrigin(3))
            // Old settings without the field still load.
            let old = #"{"iconSize":64,"gridSpacing":24,"labelPosition":"bottom","showPreviews":true}"#
            #expect((try? JSONDecoder().decode(IconOptions.self, from: Data(old.utf8)))?.snapToGrid == false)
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class SpringLoadedTabTests {
        let base = TestDirs.make("springtabs")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func tabButtonsAcceptFileDrags() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            try FileManager.default.createDirectory(at: base.appendingPathComponent("A"), withIntermediateDirectories: true)
            let a = BrowserWindowController(location: .folder(base), pendingSearch: nil)
            let b = BrowserWindowController(location: .folder(base.appendingPathComponent("A")), pendingSearch: nil)
            defer { for c in [a, b] { c.browser.state.invalidate(); c.window?.close() } }
            a.window?.tabbingMode = .preferred
            a.showWindow(nil)
            a.window?.addTabbedWindow(b.window!, ordered: .above)
            try await Task.sleep(for: .milliseconds(300))
            a.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification))
            b.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification))
            let buttons = [a, b].flatMap { SpringLoadedTabs.tabButtons(in: $0.window!.contentView!.superview!) }
            #expect(buttons.count >= 2, "found \(buttons.count) tab buttons")
            #expect(buttons.allSatisfy { $0.registeredDraggedTypes.contains(.fileURL) })
        }
    }
}

extension UISerial {
    @MainActor
    @Suite final class FiltersPopoverTests {
        @Test func addsAndRemovesFilters() async throws {
            var latest = ""
            let model = FiltersModel(text: "beach kind:images size:>5MB modified:<7d") { latest = $0 }
            #expect(model.items.count == 4)
            model.draft.field = .tag
            model.draft.text = "Work"
            model.add()
            #expect(latest == "beach kind:images size:>5MB modified:<7d tag:Work")
            model.remove(at: 0)
            #expect(latest == "kind:images size:>5MB modified:<7d tag:Work")

            let host = NSHostingView(rootView: FiltersView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 240)
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            model.draft.field = .size
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-filters.png"))
            }
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class DesktopWindowTests {
        let base = TestDirs.make("desktopwin")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func desktopShowsTheFolderAndOpensFoldersElsewhere() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let desk = base.appendingPathComponent("Desktop", isDirectory: true)
            try FileManager.default.createDirectory(at: desk.appendingPathComponent("Projects"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: desk.appendingPathComponent("notes.txt").path, contents: nil)
            let controller = DesktopWindowController(folder: desk)   // not shown on screen
            defer { controller.browser.state.invalidate() }
            let state = controller.browser.state
            let deadline = Date().addingTimeInterval(15)
            while state.snapshot.items.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(state.isDesktop && state.settingsClass == .desktop)
            #expect(state.settings.presentation.mode == .icon && state.settings.arrangement.primary.key == .manual)
            #expect(Set(state.snapshot.items.map(\.name)) == ["Projects", "notes.txt"])
            #expect(controller.window?.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)))
            #expect(controller.window?.isExcludedFromWindowsMenu == true)
            #expect(controller.windowShouldClose(controller.window!) == false)

            // Opening a folder opens a window there; the desktop stays on the Desktop folder.
            var opened: [(Location, [String])] = []
            state.openElsewhere = { opened.append(($0, $1)) }
            state.select(names: ["Projects"])
            controller.browser.openSelection(nil)
            #expect(opened.first?.0.folderURL?.lastPathComponent == "Projects")
            #expect(state.location.folderURL?.lastPathComponent == "Desktop")
            state.jump(to: .computer)
            #expect(opened.last?.0 == .computer && state.location.folderURL?.lastPathComponent == "Desktop")
        }

        @Test func desktopIconsFillColumnsFromTheRight() {
            let grid = FreeArrangement(cellSize: NSSize(width: 100, height: 100), spacing: 10, width: 1000, height: 340, fromRight: true)
            #expect(grid.rows == 3)
            let frames = grid.frames(for: ["a", "b", "c", "d"], saved: [:])
            #expect(frames[0].origin == CGPoint(x: 1000 - 14 - 100, y: 10))         // top right
            #expect(frames[1].origin == CGPoint(x: 886, y: 120))                     // down the column
            #expect(frames[3].origin == CGPoint(x: 886 - 110, y: 10))                // next column to the left
            let snapped = grid.snapped(["m": CGPoint(x: 880, y: 118)], others: ["a": frames[0].origin])
            #expect(snapped["m"] == frames[1].origin)
        }
    }
}

/// Stands in for the real system settings in tests.
@MainActor
final class FakeSystemControl: SystemControl {
    var finderDesktopShown = true
    var folderHandler: String? = "com.apple.finder"
    var loginItem = false
    var finderRunning = true
    var approveLoginItem = true
    var calls: [String] = []
    func setFinderDesktop(shown: Bool) { finderDesktopShown = shown; calls.append("desktop:\(shown)") }
    func setFolderHandler(_ bundleID: String) { folderHandler = bundleID; calls.append("folders:\(bundleID)") }
    func setLoginItem(_ on: Bool) -> Bool { loginItem = on; calls.append("login:\(on)"); return approveLoginItem }
    func quitFinder() { finderRunning = false; calls.append("quitFinder") }
    func launchFinder() { finderRunning = true; calls.append("launchFinder") }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class FinderTakeoverTests {
        let fake = FakeSystemControl()
        let suite = "rf-test-takeover-\(UUID().uuidString)"
        var viewer: String?
        var desktopShown = false
        let realRead = FileViewerSetting.read, realWrite = FileViewerSetting.write

        init() {
            // Never the real Finder, Launch Services, login items or global preferences.
            FinderTakeover.system = fake
            FinderTakeover.defaults = UserDefaults(suiteName: suite)!
            FinderTakeover.showDesktop = { [unowned self] in self.desktopShown = true }
            FinderTakeover.hideDesktop = { [unowned self] in self.desktopShown = false }
            FileViewerSetting.read = { [unowned self] in self.viewer }
            FileViewerSetting.write = { [unowned self] in self.viewer = $0 }
        }

        isolated deinit {
            FinderTakeover.system = RealSystemControl()
            FinderTakeover.defaults = .standard
            FinderTakeover.showDesktop = { DesktopWindowController.show() }
            FinderTakeover.hideDesktop = { DesktopWindowController.hide() }
            FileViewerSetting.read = realRead
            FileViewerSetting.write = realWrite
            UserDefaults().removePersistentDomain(forName: suite)
        }

        /// Only a person is asked "Quit Foray?"; an installer, a script, logout or the updater isn't.
        @Test func onlyThePersonQuittingIsAsked() {
            typealias T = FinderTakeover
            #expect(T.quitSource(updating: false, quitEventSender: nil) == .user)                    // ⌘Q, the Quit command
            #expect(T.quitSource(updating: false, quitEventSender: "com.apple.dock") == .user)       // Quit in the Dock
            #expect(T.quitSource(updating: false, quitEventSender: "") == .anotherProcess)           // osascript (Homebrew)
            #expect(T.quitSource(updating: false, quitEventSender: "com.apple.loginwindow") == .anotherProcess)
            #expect(T.quitSource(updating: false, quitEventSender: "com.apple.Terminal") == .anotherProcess)
            #expect(T.quitSource(updating: true, quitEventSender: nil) == .update)
            // With the switch off nobody is asked anything.
            #expect(!T.isEnabled && T.shouldQuit())
        }

        @Test func offUntilTheUserTurnsItOn() {
            #expect(!FinderTakeover.isEnabled)
            FinderTakeover.applyAtLaunch()
            #expect(fake.calls.isEmpty && !desktopShown && viewer == nil)
            // The Settings switch asks first; saying no changes nothing.
            let model = SettingsPaneModel()
            model.setInsteadOfFinder(true, confirm: { false })
            #expect(!model.insteadOfFinder && fake.calls.isEmpty)
        }

        @Test func onChangesEverythingAndOffPutsItBack() {
            let model = SettingsPaneModel()
            model.setInsteadOfFinder(true, confirm: { true })
            #expect(model.insteadOfFinder && FinderTakeover.isEnabled)
            #expect(desktopShown && !fake.finderDesktopShown)
            #expect(fake.folderHandler == FinderTakeover.bundleID && viewer == FinderTakeover.bundleID && fake.loginItem)
            #expect(fake.finderRunning)   // not quit unless asked
            model.quitFinder = true
            #expect(!fake.finderRunning)

            model.setInsteadOfFinder(false)
            #expect(!FinderTakeover.isEnabled && !desktopShown)
            #expect(fake.finderDesktopShown && fake.folderHandler == "com.apple.finder" && viewer == nil && !fake.loginItem)
            #expect(fake.finderRunning)
        }

        @Test func leavesAloneWhatItDidNotChange() {
            fake.finderDesktopShown = false     // the user had hidden Finder's desktop already
            fake.loginItem = true               // and added Foray to Login Items themselves
            fake.folderHandler = "com.example.OtherViewer"
            FinderTakeover.enable(quitFinder: false)
            FinderTakeover.disable()
            #expect(!fake.finderDesktopShown && fake.loginItem)
            #expect(fake.folderHandler == "com.example.OtherViewer")   // their previous choice comes back
            #expect(!fake.calls.contains("desktop:true") && !fake.calls.contains("login:false"))
        }

        @Test func keepsTheUsersChoiceAfterMacOSPutsThingsBack() {
            FinderTakeover.enable(quitFinder: true)
            fake.finderDesktopShown = true   // e.g. after a macOS update
            fake.finderRunning = true
            desktopShown = false
            FinderTakeover.applyAtLaunch()
            #expect(desktopShown && !fake.finderDesktopShown && !fake.finderRunning)
            FinderTakeover.disable()
        }

        @Test func reportsWhenLoginItemNeedsApproval() {
            fake.approveLoginItem = false
            let notes = FinderTakeover.enable(quitFinder: false)
            #expect(notes.first?.contains("Login Items") == true)
            FinderTakeover.disable()
        }
    }
}
