import Foundation
import Testing

@testable import RFFileSystem
@testable import RFUI

@MainActor
@Suite(.serialized) final class FavoritesTests {
    let base = TestDirs.make("fav")

    deinit { try? FileManager.default.removeItem(at: base) }

    private func model() -> AppModel { AppModel(store: AppSupportStore(directory: base.appendingPathComponent("store"))) }

    private func folder(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func defaultsAddMoveRemove() throws {
        let m = model()
        #expect(m.favorites == AppModel.defaultFavorites)
        let a = try folder("A"), b = try folder("B")
        m.addFavorites([a, b])
        m.addFavorites([a])                                  // duplicates are ignored
        #expect(m.favorites.suffix(2).map(\.lastPathComponent) == ["A", "B"])
        m.moveFavorite(from: m.favorites.count - 1, to: 0)   // B to the top
        #expect(m.favorites.first?.lastPathComponent == "B")
        m.removeFavorite(at: 0)
        #expect(!m.favorites.contains { $0.lastPathComponent == "B" })
    }

    @Test func persistAndSurviveRename() throws {
        let original = try folder("Projects")
        let m = model()
        m.addFavorites([original], at: 0)
        let renamed = base.appendingPathComponent("Projects 2026")
        try FileManager.default.moveItem(at: original, to: renamed)
        let reloaded = model()
        #expect(reloaded.favorites.first?.standardizedFileURL.lastPathComponent == "Projects 2026")
    }

    @Test func observersAreNotified() throws {
        let m = model()
        var calls = 0
        _ = m.observeFavorites { calls += 1 }
        m.addFavorites([try folder("C")])
        m.removeFavorite(at: m.favorites.count - 1)
        #expect(calls == 2)
    }
}
