import Foundation
import Testing

@testable import RFFileSystem
@testable import RFModel
@testable import RFSearch

struct RecentsTests {
    @Test func lastOpenedRoundTripsThroughTheAttribute() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rf-lastopened-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(LastOpened.read(file) == nil)
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(LastOpened.write(when, to: file))
        #expect(LastOpened.read(file) == when)
        let item = try #require(Recents.items([file.path]).first)
        #expect(item.lastOpened == when)
    }

    @Test func leavesOutLibraryHiddenAndSystemFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Recents.isWanted(home + "/Documents/report.pdf"))
        #expect(!Recents.isWanted(home + "/Library/Caches/x.db"))
        #expect(!Recents.isWanted(home + "/.config/settings.json"))
        #expect(!Recents.isWanted("/System/Library/x.plist"))
        #expect(Recents.queryString.contains("kMDItemLastUsedDate >= $time.today(-30)"))
    }

    @Test func sortsByDateLastOpened() {
        func item(_ name: String, _ opened: TimeInterval?) -> FileItem {
            FileItem(id: FileID(device: 1, inode: UInt64(name.hashValue.magnitude)), url: URL(fileURLWithPath: "/x/" + name), name: name,
                     contentType: .plainText, flags: [], size: 1, lastOpened: opened.map(Date.init(timeIntervalSince1970:)))
        }
        let items = [item("a", 100), item("b", 300), item("never", nil), item("c", 200)]
        let settings = ViewSettingsDatabase.builtInDefault(for: .recents)
        #expect(settings.arrangement.primary == SortDescriptor(.dateLastOpened, ascending: false))
        let snap = ArrangementEngine.arrange(items, with: settings.arrangement, generation: 1)
        #expect(snap.items.map(\.name) == ["b", "c", "a", "never"])
    }

    /// Reads (never changes) this Mac's Spotlight index. Opt-in: RF_SPOTLIGHT_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RF_SPOTLIGHT_TESTS"] != nil))
    func findsRecentlyOpenedFiles() async {
        var items: [FileItem] = []
        for await event in Recents.observe() {
            if case .complete(let list) = event { items = list; break }
        }
        print("Recents: \(items.count) items, \(items.filter { $0.lastOpened != nil }.count) with dates")
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.isNavigableFolder && Recents.isWanted($0.url.path) })
    }
}
