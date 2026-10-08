import Foundation
import Testing

@testable import RFUI

@MainActor
@Suite struct GuideTests {
    @Test func guideIsBundledAndEveryLinkHasATarget() throws {
        let url = try #require(GuideWindowController.guideURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        let ids = Set(html.matches(of: /id="([^"]+)"/).map { String($0.output.1) })
        let links = Set(html.matches(of: /href="#([^"]+)"/).map { String($0.output.1) })
        #expect(links.subtracting(ids).isEmpty, "links without targets: \(links.subtracting(ids))")
        let sections: [GuideWindowController.Section] = [.start, .views, .sorting, .settings, .search, .syntax, .kinds, .files, .keys, .access, .coming]
        for s in sections { #expect(ids.contains(s.rawValue), "missing section \(s.rawValue)") }
    }
}
