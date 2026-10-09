import Darwin
import Foundation
import Testing

@testable import RFFileSystem

struct EjectorTests {
    /// Regression: a folder path resolved to the disk holding it (usually the startup disk) and was
    /// handed to diskutil. Refused before anything runs now.
    @Test func refusesFoldersAndStartupVolumes() throws {
        let folder = FileManager.default.temporaryDirectory
        #expect(throws: Ejector.Failure.self) { try Ejector.eject(folder) }
        #expect(throws: Ejector.Failure.self) { try Ejector.unmountOnly(folder) }
        #expect(throws: Ejector.Failure.self) { try Ejector.eject(URL(fileURLWithPath: "/System/Volumes/Data")) }
        #expect(throws: Ejector.Failure.self) { try Ejector.unmountOnly(URL(fileURLWithPath: "/System/Volumes/VM")) }
    }

    @Test func refusesTheStartupDisk() {
        #expect(Ejector.wholeDevice(of: URL(fileURLWithPath: "/"))?.hasPrefix("/dev/disk") == true)
        #expect(throws: Ejector.Failure.self) { try Ejector.eject(URL(fileURLWithPath: "/")) }
    }

    /// A disk image held open by this process: eject fails naming us, Force Eject works.
    /// Opt-in (RF_FS_MATRIX=1): it attaches a disk image.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RF_FS_MATRIX"] == "1"))
    func busyVolumeNamesTheBlockerAndForceEjects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-eject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("e.dmg"), mount = dir.appendingPathComponent("mnt")
        try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "RFEject", image.path])
        try hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", mount.path, image.path])
        defer { try? hdiutil(["detach", "-force", mount.path]) }

        FileManager.default.createFile(atPath: mount.appendingPathComponent("f").path, contents: Data("x".utf8))
        let fd = open(mount.appendingPathComponent("f").path, O_RDONLY)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }

        #expect(Ejector.wholeDevice(of: mount) != nil)
        do {
            try Ejector.eject(mount)
            Issue.record("eject should have been refused")
        } catch let failure as Ejector.Failure {
            #expect(failure.blockers.contains { $0.pid == getpid() }, "\(failure)")
        }
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("f").path))

        try Ejector.eject(mount, force: true)
        #expect(!FileManager.default.fileExists(atPath: mount.appendingPathComponent("f").path))
    }

    /// Two volumes on one disk image: each sees the other as a sibling; unmounting one keeps the
    /// other. Opt-in (RF_FS_MATRIX=1); the volumes appear in /Volumes briefly.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RF_FS_MATRIX"] == "1"))
    func siblingsAndUnmountingJustOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rf-eject2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("two.dmg")
        try hdiutil(["create", "-size", "80m", "-layout", "NONE", image.path])
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-nomount", image.path]
        let out = Pipe()
        attach.standardOutput = out
        try attach.run()
        attach.waitUntilExit()
        let device = try #require(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init))
        defer { try? hdiutil(["detach", "-force", device]) }
        let part = Process()
        part.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        part.arguments = ["partitionDisk", device, "2", "GPT", "JHFS+", "RFEjectOne", "35M", "JHFS+", "RFEjectTwo", "R"]
        part.standardOutput = FileHandle.nullDevice
        try part.run()
        part.waitUntilExit()
        let one = URL(fileURLWithPath: "/Volumes/RFEjectOne"), two = URL(fileURLWithPath: "/Volumes/RFEjectTwo")
        try #require((try? two.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true)

        #expect(Ejector.siblings(of: one).map(\.standardizedFileURL.path) == ["/Volumes/RFEjectTwo"])
        try Ejector.unmountOnly(one)
        #expect((try? two.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true)   // the other stays
        #expect(!FileManager.default.fileExists(atPath: one.path) || (try? one.resourceValues(forKeys: [.isVolumeKey]))?.isVolume != true)
        try Ejector.eject(two)
        #expect(!FileManager.default.fileExists(atPath: two.path))   // (URL caches resource values; ask afresh)
    }

    private func hdiutil(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "hdiutil", code: Int(p.terminationStatus)) }
    }
}
