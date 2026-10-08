import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

extension UISerial {
    @MainActor
    @Suite(.serialized) final class ViewOptionsTests {
        let base = TestDirs.make("viewopts")
        deinit { try? FileManager.default.removeItem(at: base) }

        @Test func editsTheFrontBrowser() async throws {
            let folder = base.appendingPathComponent("F", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let state = BrowserState(location: .folder(folder))
            defer { state.invalidate() }
            let deadline = Date().addingTimeInterval(10)
            while state.details.folderKey == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

            let model = ViewOptionsModel()
            model.attach(state)
            model.attach(state)   // attaching twice is harmless
            model.sortKey.wrappedValue = .size
            #expect(state.settings.arrangement.primary.key == .size)
            model.ascending.wrappedValue = true
            #expect(state.settings.arrangement.primary == SortDescriptor(.size, ascending: true))
            model.arrangement(\.groupBy).wrappedValue = .kind
            #expect(state.settings.arrangement.groupBy == .kind)
            model.presentation(\.mode).wrappedValue = .list
            model.columnVisible(.dateAdded).wrappedValue = true
            #expect(state.settings.presentation.list.isVisible(.dateAdded))
            model.columnVisible(.dateAdded).wrappedValue = false
            #expect(!state.settings.presentation.list.isVisible(.dateAdded))

            // Pin this folder, change it, then make it the default for all folders.
            model.pinned.wrappedValue = true
            #expect(state.isPinned)
            model.presentation(\.mode).wrappedValue = .gallery
            model.useAsDefaults()
            #expect(AppModel.shared.resolve(.folder, folder: nil).0.presentation.mode == .gallery)

            let host = NSHostingView(rootView: ViewOptionsView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            model.presentation(\.mode).wrappedValue = .icon
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-viewopts.png"))
            }
        }
    }
}
