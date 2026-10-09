import Foundation
import Testing

@testable import RFUI

@Suite struct UpdaterTests {
    @Test func comparesVersions() {
        #expect(Versions.isNewer("0.9.1", than: "0.9.0"))
        #expect(Versions.isNewer("0.10.0", than: "0.9.12"))
        #expect(Versions.isNewer("1.0", than: "0.9.9"))
        #expect(!Versions.isNewer("0.9.1", than: "0.9.1"))
        #expect(!Versions.isNewer("0.9", than: "0.9.0"))
        #expect(!Versions.isNewer("0.9.0", than: "0.9.1"))
    }

    @Test func readsGitHubReleases() {
        let json = #"""
        {"tag_name":"v0.9.2","draft":false,"prerelease":false,"html_url":"https://github.com/emkey1/Foray/releases/tag/v0.9.2",
         "body":"Fixes.","assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt"},
         {"name":"Foray-0.9.2.dmg","browser_download_url":"https://github.com/emkey1/Foray/releases/download/v0.9.2/Foray-0.9.2.dmg"}]}
        """#
        let r = ReleaseInfo.parse(Data(json.utf8))
        #expect(r?.version == "0.9.2" && r?.notes == "Fixes." && r?.dmg.lastPathComponent == "Foray-0.9.2.dmg")
        #expect(ReleaseInfo.parse(Data(json.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#).utf8)) == nil)
        #expect(ReleaseInfo.parse(Data(#"{"tag_name":"v1","html_url":"https://x","assets":[]}"#.utf8)) == nil)   // no DMG
    }

    @Test func refusesToRunFromADiskImage() {
        #expect(throws: Updater.InstallError.self) { try Updater.checkInstallable(URL(fileURLWithPath: "/Volumes/Foray 0.9.1/Foray.app")) }
        #expect(throws: Updater.InstallError.self) {
            try Updater.checkInstallable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Foray.app"))
        }
    }

    @Test func onlyOurSignedNotarizedAppPasses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("Foray.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: fake.appendingPathComponent("Foray").path)
        #expect(throws: Updater.InstallError.self) { try Updater.verify(dir.appendingPathComponent("Foray.app")) }
        // The released Foray, if it's installed here, passes.
        let installed = URL(fileURLWithPath: "/Applications/Foray.app")
        if (try? installed.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true,
           Bundle(url: installed)?.bundleIdentifier == "io.github.emkey1.Foray" {
            try Updater.verify(installed)
        }
    }

    @Test func replacesTheAppAndCleansUpOnFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-upd2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ name: String, _ marker: String) throws -> URL {
            let a = dir.appendingPathComponent(name).appendingPathComponent("Foray.app/Contents")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try marker.write(to: a.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            return a.deletingLastPathComponent()
        }
        let target = try app("installed", "old"), new = try app("download", "new")
        try Updater.replace(target, with: new, verify: { _ in })
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")

        let bad = try app("bad", "evil")
        #expect(throws: Updater.InstallError.self) {
            try Updater.replace(target, with: bad, verify: { _ in throw Updater.InstallError(message: "no") })
        }
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["Foray.app"])   // nothing staged left behind
    }

    /// End to end without the network: a DMG holding the released Foray installs over a copy
    /// elsewhere. Needs the release in /Applications.
    @Test(.enabled(if: Bundle(url: URL(fileURLWithPath: "/Applications/Foray.app"))?.bundleIdentifier == "io.github.emkey1.Foray"))
    func installsFromADiskImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-upd3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stage = dir.appendingPathComponent("stage"), target = dir.appendingPathComponent("Apps/Foray.app")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(Updater.run("/usr/bin/ditto", ["/Applications/Foray.app", stage.appendingPathComponent("Foray.app").path]) == 0)
        let dmg = dir.appendingPathComponent("u.dmg")
        #expect(Updater.run("/usr/bin/hdiutil", ["create", "-srcfolder", stage.path, "-format", "UDZO", dmg.path]) == 0)
        try Updater.installFromDMG(dmg, replacing: target)
        #expect(Bundle(url: target)?.bundleIdentifier == "io.github.emkey1.Foray")
        try Updater.verify(target)
    }
}
