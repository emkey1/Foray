import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

extension UISerial {
    @MainActor
    @Suite(.serialized) final class EjectAndOpenWithTests {
        let base = TestDirs.make("eject")
        deinit { try? FileManager.default.removeItem(at: base) }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        @Test func tabsOnAVolumeThatGoesAwayMoveToComputer() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            let vol = base.appendingPathComponent("Vol", isDirectory: true)
            let inside = vol.appendingPathComponent("Sub", isDirectory: true)
            let sibling = base.appendingPathComponent("Vol2", isDirectory: true)
            for d in [inside, sibling] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let onVolume = BrowserState(location: .folder(inside))
            let elsewhere = BrowserState(location: .folder(sibling))
            defer { onVolume.invalidate(); elsewhere.invalidate() }

            EjectUI.volumeWentAway(vol)
            #expect(onVolume.location == .computer)
            #expect(elsewhere.location == .folder(sibling))   // "Vol2" isn't inside "Vol"
            #expect(!EjectUI.isEjectable(vol))
            #expect(!EjectUI.isEjectable(URL(fileURLWithPath: "/")))
        }

        @Test func openWithOffersOtherAndAlways() async throws {
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store2")))
            let folder = base.appendingPathComponent("F", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("note.txt").path, contents: Data("hi".utf8))
            let vc = BrowserViewController(location: .folder(folder))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = vc
            await wait { vc.state.loadState == .complete }
            vc.state.select(names: ["note.txt"])
            await wait { !vc.state.selectedItems.isEmpty }

            let menu = try #require(vc.openWithMenuItem(for: vc.state.selectedItems)?.submenu)
            let titles = menu.items.map(\.title)
            #expect(titles.last == "Other…")
            #expect(titles.contains { $0.hasSuffix("(default)") })
            let alternates = menu.items.filter(\.isAlternate)
            #expect(!alternates.isEmpty && alternates.allSatisfy { $0.title.hasPrefix("Always Open With ") })
            #expect(vc.selectedEjectableVolumes.isEmpty)
            #expect(!vc.validateMenuItem(NSMenuItem(title: "Eject", action: Commands.eject, keyEquivalent: "")))
            vc.state.invalidate()
        }
    }
}
