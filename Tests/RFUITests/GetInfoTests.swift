import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

@MainActor
@Suite struct GetInfoTests {
    @Test func gathersFactsAboutAnItem() throws {
        let dir = TestDirs.make("info")
        defer {
            chflags(dir.appendingPathComponent("doc.txt").path, 0)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("doc.txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("hello".utf8), attributes: [.posixPermissions: 0o640])
        _ = Tags.write(["Red"], to: url)
        let comment = try PropertyListSerialization.data(fromPropertyList: "a note", format: .binary, options: 0)
        _ = comment.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemFinderComment", $0.baseAddress, comment.count, 0, 0) }
        chflags(url.path, UInt32(UF_IMMUTABLE))

        let item = try #require(DirectoryLoader.shared.stat(url))
        let info = ItemInfo.load(item)
        #expect(info.permissions == "-rw-r----- (640)")
        #expect(info.owner == NSUserName())
        #expect(info.locked)
        #expect(info.tags.map(\.name) == ["Red"])
        #expect(info.comment == "a note")
        #expect(info.size == 5)
        #expect(info.kind == KindNames.name(for: item))
        #expect(info.mode == 0o640 && info.ownedByMe)

        // Owner/group/everyone access levels as Get Info shows them.
        let model = InfoModel(item: item)
        model.info = info
        #expect(model.access(0) == 3)   // owner: read & write
        #expect(model.access(1) == 1)   // group: read only
        #expect(model.access(2) == 0)   // everyone: no access
    }

    @Test func rendersTheWindow() async throws {
        let dir = TestDirs.make("info-render")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder/sub"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Folder/sub/a.bin").path, contents: Data(count: 10_000))
        let item = try #require(DirectoryLoader.shared.stat(dir.appendingPathComponent("Folder")))
        let model = InfoModel(item: item)
        let deadline = Date().addingTimeInterval(10)
        while (model.info == nil || model.computingSize) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.folderSize?.logical == 10_000)
        let host = NSHostingView(rootView: InfoView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/rf-info.png"))
        }
    }
}
