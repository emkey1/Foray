import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFUI

extension UISerial {
    /// What scripts, Shortcuts and `foray://` links can do (Automation), plus the AppleScript
    /// layer on top of it. Private windows, store and Trash.
    @MainActor
    @Suite(.serialized) final class AutomationTests {
        let base = TestDirs.make("automation")
        let a: URL, b: URL, trash: URL
        let manager = WindowManager()
        let savedWindows = Automation.windows

        isolated deinit {
            try? FileManager.default.removeItem(at: base)
            manager.controllersForTesting.forEach { $0.window?.close() }
            Automation.windows = savedWindows
        }

        init() throws {
            _ = NSApplication.shared
            // Standardized like the app's own URLs (/var → /private/var), so paths compare equal.
            let root = base.resolvingSymlinksInPath()
            a = root.appendingPathComponent("A", isDirectory: true)
            b = root.appendingPathComponent("B", isDirectory: true)
            trash = root.appendingPathComponent("Trash", isDirectory: true)
            for d in [a, b, trash] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            for name in ["report.pdf", "notes.txt"] {
                FileManager.default.createFile(atPath: a.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            try FileManager.default.createDirectory(at: a.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            AppModel.shared = AppModel(store: AppSupportStore(directory: root.appendingPathComponent("store")))
            let t = trash
            OperationCenter.shared = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: root.appendingPathComponent("journal"))), trash: { url in
                let dest = t.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
            Automation.windows = manager
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        private var front: BrowserWindowController? { manager.frontController }
        private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent).sorted() }

        @Test func nothingOpenMeansNoFolderAndNoSelection() {
            #expect(Automation.currentFolder == nil && Automation.selection.isEmpty && !Automation.isDualPane)
        }

        @Test func goOpensAWindowThenReusesIt() async {
            Automation.go(to: a)
            #expect(manager.controllersForTesting.count == 1)
            #expect(Automation.currentFolder == a)
            Automation.go(to: b)
            #expect(manager.controllersForTesting.count == 1 && Automation.currentFolder == b)
        }

        @Test func selectionIsReadAndSetInTheFrontWindow() async {
            Automation.go(to: a)
            await wait { front?.browser.state.snapshot.items.count == 3 }
            Automation.select([a.appendingPathComponent("report.pdf"), a.appendingPathComponent("Sub")])
            #expect(names(Automation.selection) == ["Sub", "report.pdf"])
            #expect(manager.controllersForTesting.count == 1)        // same folder: no new tab
        }

        @Test func openShowsFoldersAndRevealSelectsThemInTheirParent() async {
            Automation.open([a.appendingPathComponent("Sub")])
            #expect(Automation.currentFolder == a.appendingPathComponent("Sub"))
            Automation.reveal([a.appendingPathComponent("Sub")])
            #expect(Automation.currentFolder == a)
            await wait { names(Automation.selection) == ["Sub"] }
            #expect(names(Automation.selection) == ["Sub"])
        }

        @Test func findReturnsMatchesWithoutOpeningAnything() async {
            let found = await Automation.find("report", in: a)
            #expect(found == [a.appendingPathComponent("report.pdf")])
            #expect(await Automation.find("kind:pdf", in: a, limit: 1).count == 1)
            #expect(await Automation.find("  ", in: a).isEmpty)
            #expect(manager.controllersForTesting.isEmpty)
        }

        @Test func showSearchRunsInTheFrontWindow() async {
            Automation.go(to: a)
            Automation.showSearch("report", in: a, contents: true)
            let q = front?.browser.state.location.searchQuery
            #expect(q?.text == "report" && q?.scope == .folder(a, recursive: true) && q?.match == .namesAndContents)
            #expect(front?.pendingSearch == nil)
        }

        /// With no window, one opens and the search runs there (it doesn't just wait in the field).
        @Test func showSearchOpensAWindowIfNeeded() {
            Automation.showSearch("notes", in: a)
            #expect(manager.controllersForTesting.count == 1)
            #expect(front?.browser.state.location.searchQuery?.text == "notes")
            #expect(front?.pendingSearch == nil)
        }

        @Test func searchLinksRun() {
            var c = URLComponents(string: "foray://search")!
            c.queryItems = [.init(name: "q", value: "report kind:pdf"), .init(name: "in", value: a.path)]
            #expect(AppIntegration.open(c.url!))
            #expect(front?.browser.state.location.searchQuery?.text == "report kind:pdf")
        }

        @Test func revealLinksSelectFoldersInTheirParent() throws {
            var c = URLComponents(string: "foray://reveal")!
            c.queryItems = [.init(name: "path", value: a.appendingPathComponent("Sub").path)]
            let (location, select) = try #require(AppIntegration.location(for: c.url!))
            #expect(location == .folder(a) && select == ["Sub"])
            c.queryItems = [.init(name: "path", value: "/")]
            #expect(AppIntegration.location(for: c.url!) == nil)
        }

        @Test func trashGoesThroughTheOperationEngine() async {
            let problems = await Automation.trash([a.appendingPathComponent("notes.txt")])
            #expect(problems.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: a.appendingPathComponent("notes.txt").path))
            #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("notes.txt").path))
            #expect(OperationCenter.shared.undoManager.canUndo)       // like trashing in a window
            // A missing item is reported, not thrown.
            OperationCenter.shared.reportProblems = { _, _ in }      // no alert in tests
            let missing = await Automation.trash([a.appendingPathComponent("nope.txt")])
            #expect(missing.count == 1 && missing[0].contains("nope.txt"))
        }

        @Test func dualPaneCanBeSwitched() {
            Automation.go(to: a)
            Automation.setDualPane(true)
            #expect(Automation.isDualPane && front?.panes.count == 2)
            Automation.setDualPane(false)
            #expect(!Automation.isDualPane)
        }

        // MARK: AppleScript

        @Test func applicationPropertiesForScripts() async {
            let app = NSApplication.shared
            app.scriptCurrentFolder = a
            #expect(app.scriptCurrentFolder == a)
            await wait { front?.browser.state.snapshot.items.count == 3 }
            app.scriptSelection = [a.appendingPathComponent("notes.txt")]
            #expect(names(app.scriptSelection) == ["notes.txt"])
            app.scriptDualPane = true
            #expect(app.scriptDualPane && front?.isDualPane == true)
            // Cocoa scripting reaches them by key.
            #expect(app.value(forKey: "scriptCurrentFolder") as? URL == a)
            #expect((app.value(forKey: "scriptSelection") as? [URL]).map(names) == ["notes.txt"])
        }

        @Test func revealAndSearchCommands() async {
            let reveal = RevealScriptCommand()
            reveal.directParameter = [a.appendingPathComponent("report.pdf")]
            _ = reveal.performDefaultImplementation()
            #expect(Automation.currentFolder == a)
            await wait { names(Automation.selection) == ["report.pdf"] }
            #expect(names(Automation.selection) == ["report.pdf"])

            let search = SearchScriptCommand()
            search.directParameter = "notes"
            search.arguments = ["folder": a, "contents": true]
            _ = search.performDefaultImplementation()
            let q = front?.browser.state.location.searchQuery
            #expect(q?.text == "notes" && q?.scope == .folder(a, recursive: true) && q?.match == .namesAndContents)
        }

        /// The dictionary the app ships names every command class and property key that exists.
        @Test func dictionaryMatchesTheCode() throws {
            let sdef = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Foray.sdef")
            let doc = try XMLDocument(contentsOf: sdef)
            let classes = try doc.nodes(forXPath: "//suite[@name='Foray Suite']/command/cocoa/@class").compactMap(\.stringValue)
            #expect(Set(classes) == ["ForayRevealCommand", "ForaySearchCommand", "ForayFindCommand", "ForayTrashCommand"])
            for name in classes { #expect(NSClassFromString(name) is NSScriptCommand.Type, "\(name) isn't a script command class") }
            let keys = try doc.nodes(forXPath: "//class-extension/property/cocoa/@key").compactMap(\.stringValue)
            #expect(Set(keys) == ["scriptCurrentFolder", "scriptSelection", "scriptDualPane"])
            for key in keys { #expect(NSApplication.shared.responds(to: Selector(key)), "NSApplication has no \(key)") }
            // Four-character codes are unique within the suite's commands.
            let codes = try doc.nodes(forXPath: "//suite[@name='Foray Suite']/command/@code").compactMap(\.stringValue)
            #expect(Set(codes).count == codes.count && codes.allSatisfy { $0.count == 8 })
        }
    }
}
