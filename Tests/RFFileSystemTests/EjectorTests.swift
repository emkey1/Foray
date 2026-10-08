import Darwin
import Foundation
import Testing

@testable import RFFileSystem

struct EjectorTests {
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
