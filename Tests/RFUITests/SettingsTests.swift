import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFSearch
@testable import RFUI

extension UISerial {
    @MainActor
    @Suite(.serialized) final class AppSettingsTests {
        let base = TestDirs.make("settings")
        private static let keys = ["NewWindowFolder", "OpenFoldersInTabs", "ReturnOpens", "SearchScopeDefault",
                                   "LastSearchWasThisMac", "DefaultMatch"]
        private let saved: [String: Any?]

        init() {
            saved = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        }

        isolated deinit {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: base)
        }

        @Test func searchScopeFollowsTheSetting() throws {
            let folder = base.appendingPathComponent("F", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let state = BrowserState(location: .folder(folder))
            defer { state.invalidate() }

            AppSettings.searchScopeDefault = .currentFolder
            #expect(state.defaultSearchScope == .folder(folder, recursive: true))
            AppSettings.searchScopeDefault = .thisMac
            #expect(state.defaultSearchScope == .thisMac)
            AppSettings.searchScopeDefault = .previous
            AppSettings.lastSearchWasThisMac = false
            #expect(state.defaultSearchScope == .folder(folder, recursive: true))
            AppSettings.lastSearchWasThisMac = true
            #expect(state.defaultSearchScope == .thisMac)

            AppSettings.searchScopeDefault = .currentFolder
            AppSettings.defaultMatch = .namesAndContents
            state.search("report")
            #expect(state.location.searchQuery?.match == .namesAndContents)
            #expect(state.location.searchQuery?.scope == .folder(folder, recursive: true))
        }

        @Test func paneModelWritesThrough() throws {
            let model = SettingsPaneModel()
            model.returnOpens = true
            #expect(AppSettings.returnOpens)
            model.openFoldersInTabs = false
            #expect(!AppSettings.openFoldersInTabs)
            model.newWindowFolder = base
            #expect(AppSettings.newWindowLocation == .folder(base))
            model.newWindowFolder = nil
            #expect(AppSettings.newWindowLocation == .folder(FileManager.default.homeDirectoryForCurrentUser))
            model.searchScope = .thisMac
            #expect(AppSettings.searchScopeDefault == .thisMac)

            let host = NSHostingView(rootView: SettingsView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 340)
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-settings.png"))
            }
        }
    }
}
