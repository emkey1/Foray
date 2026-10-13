import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFOperations
@testable import RFSearch
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

extension UISerial {
    @MainActor
    @Suite(.serialized) final class FolderSizeTests {
        let base = TestDirs.make("foldersizes")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func calculateAllSizesSortsFoldersAmongFiles() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let work = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("Big/inner"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("Small"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: work.appendingPathComponent("Big/inner/x.bin").path, contents: Data(count: 50_000))
            FileManager.default.createFile(atPath: work.appendingPathComponent("Small/y.bin").path, contents: Data(count: 10))
            FileManager.default.createFile(atPath: work.appendingPathComponent("mid.bin").path, contents: Data(count: 1_000))

            let state = BrowserState(location: .folder(work))
            defer { state.invalidate() }
            func waitFor(_ c: () -> Bool) async {
                let deadline = Date().addingTimeInterval(15)
                while !c() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
            await waitFor { state.loadState == .complete && state.snapshot.items.count == 3 }
            state.updatePresentation { $0.mode = .list }
            state.updateArrangement { $0.sort = [SortDescriptor(.size, ascending: false)]; $0.foldersFirst = false }
            await waitFor { state.snapshot.items.map(\.name) == ["mid.bin", "Big", "Small"] }
            #expect(state.snapshot.items.map(\.name) == ["mid.bin", "Big", "Small"])   // folders have no size yet

            state.updatePresentation { $0.list.calculateAllSizes = true }
            await waitFor { state.snapshot.items.map(\.name) == ["Big", "mid.bin", "Small"] }
            #expect(state.snapshot.items.map(\.name) == ["Big", "mid.bin", "Small"])
            #expect(state.snapshot.items.first?.size == 50_000)

            state.updatePresentation { $0.list.calculateAllSizes = false }
            await waitFor { state.snapshot.items.first?.name == "mid.bin" }
            #expect(state.snapshot.items.first(where: { $0.name == "Big" })?.size == nil)
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class ConnectToServerTests {
        let suite = "rf-test-servers-\(UUID().uuidString)"

        /// Every test here gets its own, empty server history (never the test runner's own
        /// defaults, where entries would carry over from one run to the next).
        init() {
            ServerHistory.defaults = UserDefaults(suiteName: suite)!
            for key in ["ServerFavorites", "RecentServers"] { UserDefaults.standard.removeObject(forKey: key) }
        }

        isolated deinit {
            UserDefaults().removePersistentDomain(forName: suite)
            ServerHistory.defaults = .standard
        }

        @Test func historyKeepsTheLatestTenWithoutDuplicates() throws {
            ServerHistory.defaults = try #require(UserDefaults(suiteName: suite))
            for i in 1...12 { ServerHistory.noteConnected("smb://s\(i)") }
            ServerHistory.noteConnected("smb://s5")
            #expect(ServerHistory.recents.count == 10)
            #expect(ServerHistory.recents.first == "smb://s5")
            #expect(ServerHistory.recents.filter { $0 == "smb://s5" }.count == 1)

            let model = ConnectModel()
            model.address = "nas/Media"
            #expect(model.isValid)
            model.addFavorite()
            model.addFavorite()
            #expect(ServerHistory.favorites == ["nas/Media"])
            model.removeFavorite("nas/Media")
            #expect(ServerHistory.favorites.isEmpty)
            model.address = "  "
            #expect(!model.isValid)
        }

        @Test func discoveredServersAppearInTheSidebar() {
            let sidebar = SidebarViewController()
            _ = sidebar.view
            NetworkBrowser.shared.setServicesForTesting(["Office NAS"])
            defer { NetworkBrowser.shared.setServicesForTesting([]) }
            let network = sidebar.sectionsForTesting.first { $0.title == "Network" }
            #expect(network?.children.map(\.title) == ["Office NAS", "Connect to Server…"])
            #expect(network?.children.first?.action != nil && network?.children.first?.isSection == false)
        }

        /// Network is always in the sidebar, with a way in, even when nothing announces itself
        /// (plenty of Samba servers don't). Servers connected to before are listed there too.
        @Test func networkIsAlwaysThereWithSavedServers() {
            let sidebar = SidebarViewController()
            _ = sidebar.view
            NetworkBrowser.shared.setServicesForTesting([])
            defer { NetworkBrowser.shared.setServicesForTesting([]) }
            func rows() -> [String] { sidebar.sectionsForTesting.first { $0.title == "Network" }?.children.map(\.title) ?? [] }
            #expect(rows() == ["Connect to Server…"])

            // Favorites first, then recent ones, each once; the sidebar follows changes.
            ServerHistory.favorites = ["smb://nas.local/Media"]
            ServerHistory.noteConnected("192.168.1.20/backup")
            ServerHistory.noteConnected("smb://nas.local/Media")
            #expect(rows() == ["nas.local/Media", "192.168.1.20/backup", "Connect to Server…"])
            #expect(sidebar.sectionsForTesting.first { $0.title == "Network" }?.children.allSatisfy { $0.action != nil } == true)

            // A saved address for a server that's listed anyway isn't shown twice.
            ServerHistory.noteConnected("smb://Office-NAS.local")
            NetworkBrowser.shared.setServicesForTesting(["Office-NAS"])
            #expect(rows() == ["Office-NAS", "nas.local/Media", "192.168.1.20/backup", "Connect to Server…"])

            // Local Network access turned off: say so, since that's why nothing is found.
            NetworkBrowser.shared.setServicesForTesting([], accessDenied: true)
            #expect(rows().suffix(2) == ["Allow Network Access…", "Connect to Server…"])
        }

        /// Windows-style servers (a Raspberry Pi running Samba, say) are listed too, once each.
        @Test func windowsStyleServersAreListed() {
            let sidebar = SidebarViewController()
            _ = sidebar.view
            defer { NetworkBrowser.shared.setServicesForTesting([]) }
            func rows() -> [String] { sidebar.sectionsForTesting.first { $0.title == "Network" }?.children.map(\.title) ?? [] }
            let pi = NetBIOSDiscovery.Host(name: "RPI", workgroup: "WORKGROUP", address: "192.168.1.20")
            let mac = NetBIOSDiscovery.Host(name: "ANNAS-MACBOOK-P", workgroup: "WORKGROUP", address: "192.168.1.30")
            NetworkBrowser.shared.setServicesForTesting(["Anna's MacBook Pro"], windowsHosts: [mac, pi])
            // The Mac announces itself both ways and is listed once, under its Bonjour name; the Pi
            // only answers the Windows way, and is shown in lower case as Finder does.
            #expect(rows() == ["Anna's MacBook Pro", "rpi", "Connect to Server…"])
            // An address saved for a server that's now listed isn't shown as well.
            ServerHistory.noteConnected("smb://rpi/nas")
            ServerHistory.noteConnected("192.168.1.20/nas")
            ServerHistory.noteConnected("smb://other-nas/data")
            #expect(rows() == ["Anna's MacBook Pro", "rpi", "other-nas/data", "Connect to Server…"])
            // A Mac whose two names have nothing in common is still one machine: same address.
            let mini = NetBIOSDiscovery.Host(name: "M4-2", workgroup: "WORKGROUP", address: "192.168.1.40")
            NetworkBrowser.shared.setServicesForTesting(["Studio Mac mini"], windowsHosts: [mini, pi], bonjourAddresses: ["192.168.1.40"])
            #expect(rows().prefix(2) == ["Studio Mac mini", "rpi"])
            // Or, on Wi-Fi and Ethernet at once with a different address on each, the same host name.
            NetworkBrowser.shared.setServicesForTesting(["Studio Mac mini"], windowsHosts: [mini, pi],
                                                        bonjourAddresses: ["192.168.1.41"], bonjourHosts: ["m4-2"])
            #expect(rows().prefix(2) == ["Studio Mac mini", "rpi"])
            // With neither in common, they're listed as two machines.
            NetworkBrowser.shared.setServicesForTesting(["Studio Mac mini"], windowsHosts: [mini, pi], bonjourAddresses: ["192.168.1.41"])
            #expect(rows().prefix(3) == ["Studio Mac mini", "m4-2", "rpi"])
        }

        @Test func sameMachineUnderTwoNames() {
            #expect(NetworkBrowser.isSameMachine(windowsName: "MBP5", bonjourName: "MBP5"))
            #expect(NetworkBrowser.isSameMachine(windowsName: "ANNAS-MACBOOK-P", bonjourName: "Anna's MacBook Pro"))
            #expect(NetworkBrowser.isSameMachine(windowsName: "OFFICE-NAS", bonjourName: "Office NAS"))
            #expect(!NetworkBrowser.isSameMachine(windowsName: "RPI", bonjourName: "Anna's MacBook Pro"))
            #expect(!NetworkBrowser.isSameMachine(windowsName: "NAS", bonjourName: "NAS2"))      // short names must match exactly
            #expect(!NetworkBrowser.isSameMachine(windowsName: "", bonjourName: ""))
        }

        @Test func serverTitlesDropTheUsualScheme() {
            #expect(ServerHistory.title(for: "smb://nas.local/Media") == "nas.local/Media")
            #expect(ServerHistory.title(for: "nas/Media/") == "nas/Media")
            #expect(ServerHistory.title(for: "afp://old-mac.local") == "afp://old-mac.local")
        }
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class SmartFolderUITests {
        let base = TestDirs.make("smartui")
        isolated deinit { try? FileManager.default.removeItem(at: base) }

        @Test func openingASmartFolderRunsItAndItCanSitInTheSidebar() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let work = base.appendingPathComponent("W", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let saved = work.appendingPathComponent("Reports.savedSearch")
            try SavedSearch.write(SearchQuery(text: "report", scope: .folder(work, recursive: true)), to: saved)

            let vc = BrowserViewController(location: .folder(work))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            defer { vc.state.invalidate() }
            let deadline = Date().addingTimeInterval(15)
            while vc.state.snapshot.items.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            vc.state.select(names: ["Reports.savedSearch"])
            while vc.state.selectedItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            vc.openSelection(nil)
            #expect(vc.state.location.searchQuery?.text == "report")
            let save = NSMenuItem(title: "", action: #selector(BrowserViewController.saveSearch(_:)), keyEquivalent: "")
            #expect(vc.validateMenuItem(save))

            AppModel.shared.addFavorites([saved])
            let sidebar = SidebarViewController()
            _ = sidebar.view
            let node = sidebar.sectionsForTesting.first?.children.first { $0.title == "Reports" }
            #expect(node?.location?.searchQuery?.text == "report")
        }
    }
}
