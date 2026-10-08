import Foundation
import Testing

@testable import RFModel

struct BatchRenameRuleTests {
    let items: [(name: String, modified: Date?)] = [("IMG_0001.JPG", nil), ("IMG_0002.JPG", nil), ("notes.txt", nil)]

    @Test func replaceTextIgnoresTheExtensionUnlessAsked() {
        var r = RenameRule()
        r.find = "img_"
        r.replacement = "Trip "
        #expect(r.newNames(for: items) == ["Trip 0001.JPG", "Trip 0002.JPG", "notes.txt"])
        r.caseSensitive = true
        #expect(r.newNames(for: items)[0] == "IMG_0001.JPG")
        r = RenameRule()
        r.find = "JPG"
        r.replacement = "jpeg"
        #expect(r.newNames(for: items)[0] == "IMG_0001.JPG")
        r.includeExtension = true
        #expect(r.newNames(for: items)[0] == "IMG_0001.jpeg")
    }

    @Test func regexWithGroups() {
        var r = RenameRule()
        r.useRegex = true
        r.find = #"IMG_0*(\d+)"#
        r.replacement = "Photo $1"
        #expect(r.newNames(for: items) == ["Photo 1.JPG", "Photo 2.JPG", "notes.txt"])
        r.find = "(("
        #expect(r.regexProblem != nil)
    }

    @Test func addFormatAndCase() {
        var r = RenameRule()
        r.mode = .add
        r.text = "-final"
        #expect(r.newNames(for: items)[2] == "notes-final.txt")
        r.position = .before
        r.text = "2026 "
        #expect(r.newNames(for: items)[2] == "2026 notes.txt")

        r = RenameRule()
        r.mode = .format
        r.baseName = "Beach"
        r.startAt = 7
        #expect(r.newNames(for: items) == ["Beach 7.JPG", "Beach 8.JPG", "Beach 9.txt"])
        r.numberStyle = .counter
        r.numberPosition = .before
        #expect(r.newNames(for: items)[0] == "00007 Beach.JPG")

        r = RenameRule()
        r.mode = .changeCase
        r.newCase = .title
        #expect(r.newNames(for: [("hello world.TXT", nil)]) == ["Hello World.TXT"])
    }

    @Test func problemsCatchClashesAndBadNames() {
        let old = ["a.txt", "b.txt", "c.txt"]
        let p = RenameRule.problems(old: old, new: ["x.txt", "X.txt", "d.txt"], existing: ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(p[0] != nil && p[1] != nil)          // same name (case-insensitively)
        #expect(p[2] == "An item with this name already exists")
        // Swapping names within the batch is fine.
        #expect(RenameRule.problems(old: ["a", "b"], new: ["b", "a"], existing: ["a", "b"]).isEmpty)
        #expect(RenameRule.problems(old: ["a"], new: ["x/y"], existing: ["a"])[0] != nil)
    }
}
