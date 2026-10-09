import Foundation
import Testing

@testable import RFModel

struct SearchFiltersTests {
    @Test func describesFiltersInWords() {
        let d = { SearchFilters.describe($0) }
        #expect(d("size:>5MB") == "Size is larger than 5 MB")
        #expect(d("size:1MB..5MB") == "Size is between 1 MB and 5 MB")
        #expect(d("modified:<7d") == "Modified within the last 7 days")
        #expect(d("created:<1w") == "Created within the last week")
        #expect(d("opened:>1y") == "Last opened more than 1 year ago")
        #expect(d("added:2026") == "Added in 2026")
        #expect(d("modified:today") == "Modified today")
        #expect(d("kind:images,pdf") == "Kind is Images or PDFs")
        #expect(d("ext:pdf,docx") == "Extension is .pdf or .docx")
        #expect(d("tag:\"Work Stuff\"") == "Tagged “Work Stuff”")
        #expect(d("report") == "Name contains “report”")
        #expect(d("-kind:folders") == "Not: Kind is Folders")
        #expect(d("hidden:yes") == "Including hidden files")
        #expect(d("/^IMG_\\d+$/") == "Name matches /^IMG_\\d+$/")
    }

    @Test func draftsBecomeFilterText() {
        var draft = SearchFilters.Draft()
        draft.field = .size
        draft.number = 5
        #expect(draft.token == "size:>5MB")
        draft.field = .modified
        draft.dateComparison = .withinLast
        draft.number = 2
        draft.dateUnit = .weeks
        #expect(draft.token == "modified:<2w")
        draft.dateComparison = .inYear
        draft.year = 2024
        #expect(draft.token == "modified:2024")
        draft.field = .tag
        draft.text = "Work Stuff"
        #expect(draft.token == "tag:\"Work Stuff\"")
        draft.field = .name
        draft.text = "  "
        #expect(draft.token == nil)
        draft.field = .ext
        draft.text = ".PDF"
        #expect(draft.token == "ext:pdf")
        // Every built filter reads back without problems.
        for field in SearchFilters.Field.allCases {
            var d = SearchFilters.Draft()
            d.field = field
            d.text = "x"
            d.number = 3
            if let token = d.token { #expect(QueryParser.problems(in: token).isEmpty, "\(token)") }
        }
    }

    @Test func addsAndRemovesWithinTheText() {
        var text = SearchFilters.adding("kind:images", to: "beach")
        text = SearchFilters.adding("size:>1MB", to: text)
        #expect(text == "beach kind:images size:>1MB")
        #expect(SearchFilters.items(in: text).map(\.description) == ["Name contains “beach”", "Kind is Images", "Size is larger than 1 MB"])
        #expect(SearchFilters.removing(at: 1, from: text) == "beach size:>1MB")
        #expect(SearchFilters.removing(at: 0, from: "a OR b") == "b")
    }
}
