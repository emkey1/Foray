import Darwin
import Foundation

/// Unmounting and ejecting (DESIGN.md §5.9). `diskutil` does the work: it handles APFS containers,
/// disk images and multi-volume devices, and names the process that refused the unmount.
public enum Ejector {
    public struct Blocker: Hashable, Sendable {
        public let pid: Int32
        public let name: String
    }

    public struct Failure: Error, Sendable, LocalizedError {
        public let message: String
        /// Processes with files open on the volume (ours only; other users' need root to see).
        public let blockers: [Blocker]
        public var errorDescription: String? { message }

        public init(message: String, blockers: [Blocker]) {
            self.message = message
            self.blockers = blockers
        }
    }

    /// Unmounts every volume on the device and ejects it. `force` unmounts even with files open.
    /// Network and other non-disk mounts are unmounted.
    public static func eject(_ volume: URL, force: Bool = false) throws {
        let path = volume.standardizedFileURL.path
        guard path != "/" else { throw Failure(message: "The startup disk can't be ejected.", blockers: []) }
        if let device = wholeDevice(of: volume) {
            if force {
                try run(["unmountDisk", "force", device], volume: path)
                try run(["eject", device], volume: path)
            } else {
                try run(["eject", device], volume: path)
            }
        } else {
            try run(force ? ["unmount", "force", path] : ["unmount", path], volume: path)
        }
    }

    /// `/dev/diskN` for a volume on a disk (nil for network and synthetic mounts).
    public static func wholeDevice(of volume: URL) -> String? {
        var fs = statfs()
        guard statfs(volume.path, &fs) == 0 else { return nil }
        let from = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard let match = from.firstMatch(of: /^\/dev\/disk\d+/) else { return nil }
        return String(match.output)
    }

    /// Processes with files open on the volume, from `lsof` (best effort, a few seconds at most).
    public static func blockers(of volume: URL) -> [Blocker] {
        guard let out = try? execute("/usr/sbin/lsof", ["-Fpc", "+f", "--", volume.path], timeout: 5).output else { return [] }
        var result: [Blocker] = []
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), let p = pid { result.append(Blocker(pid: p, name: String(line.dropFirst()))) }
        }
        return Array(Set(result)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func run(_ args: [String], volume: String) throws {
        let (status, output) = try execute("/usr/sbin/diskutil", args, timeout: 60)
        guard status != 0 else { return }
        var blockers = blockers(of: URL(fileURLWithPath: volume))
        // diskutil: "Unmount was dissented by PID 20345 (/bin/sleep)"
        for m in output.matches(of: /dissented by PID (\d+) \(([^)]*)\)/) {
            if let pid = Int32(m.output.1), !blockers.contains(where: { $0.pid == pid }) {
                blockers.append(Blocker(pid: pid, name: (String(m.output.2) as NSString).lastPathComponent))
            }
        }
        let message = output.split(separator: "\n").first.map(String.init) ?? "diskutil \(args.joined(separator: " ")) failed"
        throw Failure(message: message, blockers: blockers)
    }

    private static func execute(_ tool: String, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
