import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

extension UISerial {
    /// Opening a disk image shows its volume once it's mounted. Nothing is mounted here: the list
    /// of attached images, the mount notification and the windows are all stand-ins.
    @MainActor
    @Suite(.serialized) final class DiskImageTests {
        let base = TestDirs.make("diskimage")
        let image: URL
        let volume = URL(fileURLWithPath: "/Volumes/Demo Disk", isDirectory: true)
        var shownInTab: [URL] = []
        var shownInWindow: [URL] = []
        let fake = FakeSystemControl()
        let suite = "rf-test-diskimage-\(UUID().uuidString)"
        private let saved = (DiskImages.attached, DiskImages.isBrowsable, DiskImages.showInNewWindow, BrowserViewController.openFile)
        var opened: [URL] = []

        init() throws {
            _ = NSApplication.shared
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            image = base.resolvingSymlinksInPath().appendingPathComponent("Installer.dmg")
            FileManager.default.createFile(atPath: image.path, contents: Data("not really an image".utf8))
            AppModel.shared = AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store")))
            DiskImages.attached = { [:] }
            DiskImages.isBrowsable = { _ in true }
            DiskImages.showInNewWindow = { [unowned self] in self.shownInWindow.append($0) }
            BrowserViewController.openFile = { [unowned self] in self.opened.append($0) }
            // "Use Foray instead of Finder" with stand-ins, never the real settings.
            FinderTakeover.system = fake
            FinderTakeover.defaults = UserDefaults(suiteName: suite)!
        }

        isolated deinit {
            (DiskImages.attached, DiskImages.isBrowsable, DiskImages.showInNewWindow, BrowserViewController.openFile) = saved
            FinderTakeover.system = RealSystemControl()
            FinderTakeover.defaults = .standard
            UserDefaults().removePersistentDomain(forName: suite)
            // Nothing left waiting for the next test.
            DiskImages.volumeMounted(URL(fileURLWithPath: "/Volumes/leftover"))
            DiskImages.volumeMounted(URL(fileURLWithPath: "/Volumes/leftover"))
            try? FileManager.default.removeItem(at: base)
        }

        private func wait(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }

        /// A browser on the folder with the image, whose "new tab" requests are recorded.
        private func browser() async -> BrowserViewController {
            let vc = BrowserViewController(location: .folder(image.deletingLastPathComponent()))
            vc.openInNewTab = { [unowned self] location in if let url = location.folderURL { self.shownInTab.append(url) } }
            _ = vc.view
            await wait { vc.state.snapshot.items.contains { $0.name == "Installer.dmg" } }
            return vc
        }

        private func openImage(_ vc: BrowserViewController) {
            vc.open(vc.state.snapshot.items.filter { $0.name == "Installer.dmg" }, inNewTab: false)
        }

        @Test func knowsDiskImagesByKind() async {
            let vc = await browser()
            defer { vc.state.invalidate() }
            let item = vc.state.snapshot.items.first { $0.name == "Installer.dmg" }!
            #expect(DiskImages.isDiskImage(item))
            FileManager.default.createFile(atPath: image.deletingLastPathComponent().appendingPathComponent("notes.txt").path, contents: nil)
            vc.state.reload()
            await wait { vc.state.snapshot.items.contains { $0.name == "notes.txt" } }
            #expect(!DiskImages.isDiskImage(vc.state.snapshot.items.first { $0.name == "notes.txt" }!))
        }

        @Test func openingAnImageShowsItsDiskWhenItMounts() async {
            let vc = await browser()
            defer { vc.state.invalidate() }
            openImage(vc)
            #expect(opened == [image])                       // macOS still does the mounting
            #expect(shownInTab.isEmpty)                      // nothing to show until the disk is there
            await Task.yield()
            DiskImages.volumeMounted(volume)                 // the disk appears
            #expect(shownInTab == [volume])
            // Only once: a second disk turning up later isn't this image's.
            DiskImages.volumeMounted(URL(fileURLWithPath: "/Volumes/USB Stick"))
            #expect(shownInTab == [volume] && shownInWindow.isEmpty)
        }

        @Test func anImageThatIsAlreadyMountedIsShownStraightAway() async {
            let path = image.path, mounted = volume
            DiskImages.attached = { [path: [mounted]] }
            let vc = await browser()
            defer { vc.state.invalidate() }
            openImage(vc)
            await wait { !shownInTab.isEmpty }
            #expect(shownInTab == [volume])
            // And it isn't still waiting for a disk: the next one to mount is left alone.
            DiskImages.volumeMounted(URL(fileURLWithPath: "/Volumes/USB Stick"))
            #expect(shownInTab == [volume])
        }

        @Test func hiddenMountsAreIgnored() async {
            let vc = await browser()
            defer { vc.state.invalidate() }
            DiskImages.isBrowsable = { $0.path != "/Volumes/Hidden" }
            openImage(vc)
            await Task.yield()
            DiskImages.volumeMounted(URL(fileURLWithPath: "/Volumes/Hidden"))    // a tool's private mount
            #expect(shownInTab.isEmpty)
            DiskImages.volumeMounted(volume)
            #expect(shownInTab == [volume])
        }

        @Test func imagesOpenedElsewhereShowOnlyWhileForayStandsInForFinder() async {
            let mounted = volume
            DiskImages.attached = { ["/Users/someone/Downloads/App.dmg": [mounted]] }
            // Finder is in charge: it shows the disk, Foray stays out of it.
            DiskImages.volumeMounted(volume)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(shownInWindow.isEmpty)
            // Foray stands in for Finder: a disk image opened from, say, Safari gets a Foray window…
            FinderTakeover.showDesktop = {}
            FinderTakeover.hideDesktop = {}
            let viewer = (FileViewerSetting.read, FileViewerSetting.write)
            FileViewerSetting.read = { nil }
            FileViewerSetting.write = { _ in }
            defer {
                FinderTakeover.disable()
                (FileViewerSetting.read, FileViewerSetting.write) = viewer
                FinderTakeover.showDesktop = { DesktopWindowController.show() }
                FinderTakeover.hideDesktop = { DesktopWindowController.hide() }
            }
            FinderTakeover.enable(quitFinder: false)
            DiskImages.volumeMounted(volume)
            await wait { !shownInWindow.isEmpty }
            #expect(shownInWindow == [volume])
            // …but a USB drive (not a disk image) just turns up in the sidebar.
            DiskImages.volumeMounted(URL(fileURLWithPath: "/Volumes/USB Stick"))
            try? await Task.sleep(for: .milliseconds(100))
            #expect(shownInWindow == [volume])
        }

        @Test func readsTheListOfAttachedImages() throws {
            let plist: [String: Any] = ["images": [
                ["image-path": "/Users/me/Downloads/App.dmg",
                 "system-entities": [["dev-entry": "/dev/disk5"], ["dev-entry": "/dev/disk5s1", "mount-point": "/Volumes/App"]]],
                ["image-path": "/tmp/unmounted.dmg", "system-entities": [["dev-entry": "/dev/disk6"]]],
            ]]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let parsed = DiskImages.parse(hdiutilInfo: data)
            #expect(parsed == ["/Users/me/Downloads/App.dmg": [URL(fileURLWithPath: "/Volumes/App", isDirectory: true)]])
            #expect(DiskImages.parse(hdiutilInfo: Data("garbage".utf8)).isEmpty)
        }
    }
}
