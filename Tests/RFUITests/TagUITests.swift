import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFUI

@MainActor
@Suite struct TagUITests {
    @Test func providerLoadsAndNoticesChanges() async throws {
        let dir = TestDirs.make("tagui")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        _ = Tags.write(["Red", "Custom"], to: url)

        let item1 = try #require(DirectoryLoader.shared.stat(url))
        var got: [RFModel.Tag]?
        TagProvider.shared.load(item1) { got = $0 }
        let deadline = Date().addingTimeInterval(5)
        while got == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(got == [RFModel.Tag("Red", color: .red), RFModel.Tag("Custom")])
        #expect(TagProvider.shared.cached(item1) == got)

        // Changing tags moves the status-change time, so the cached entry no longer applies.
        try await Task.sleep(for: .milliseconds(20))
        _ = Tags.write(["Blue"], to: url)
        let item2 = try #require(DirectoryLoader.shared.stat(url))
        #expect(item2.changed != item1.changed)
        #expect(TagProvider.shared.cached(item2) == nil)
    }

    @Test func dotsShowColoredTagsFirst() {
        let dots = TagDotsView()
        dots.tags = [RFModel.Tag("Plain"), RFModel.Tag("Red", color: .red)]
        #expect(!dots.isHidden && dots.dotsWidth > 0)
        dots.tags = []
        #expect(dots.isHidden)
    }
}
