import AppKit
import RFModel
import UniformTypeIdentifiers

/// Showing a disk image's contents once it's mounted. Opening a .dmg only mounts it (macOS's
/// DiskImageMounter does that); it's Finder that then opens a window on the new disk. Foray does
/// the same for images opened in Foray, and, while it stands in for Finder, for images opened
/// anywhere (a download opened from Safari, say). Without this, with Finder quit, double-clicking
/// a disk image looked like nothing had happened.
@MainActor
public enum DiskImages {
    /// Mounted images: the image file's path → where its volumes are mounted. Tests substitute it.
    static var attached: @Sendable () async -> [String: [URL]] = { await Task.detached { hdiutilInfo() }.value }
    /// Whether a volume is one people browse (not mounted hidden, as installers and tools do).
    static var isBrowsable: (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable ?? false
    }
    /// How a volume is shown when no window asked for it.
    static var showInNewWindow: (URL) -> Void = { WindowManager.shared.reveal([$0]) }

    /// Images opened in Foray whose disks haven't appeared yet. Big or verified images take a while.
    private static var waiting: [(until: Date, show: (URL) -> Void)] = []
    static let patience: TimeInterval = 120
    private static var observer: NSObjectProtocol?

    static func isDiskImage(_ item: FileItem) -> Bool {
        item.contentType.conforms(to: .diskImage) || UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .diskImage) == true
    }

    /// Call when Foray opens a disk image file. `show` gets the mounted volume: straight away if
    /// the image was already mounted, otherwise when its disk appears.
    static func opened(_ image: URL, show: @escaping (URL) -> Void) {
        let path = image.resolvingSymlinksInPath().path
        waiting.removeAll { $0.until < Date() }
        let ticket = Date().addingTimeInterval(patience)
        waiting.append((ticket, show))
        Task { @MainActor in
            // Already mounted: opening it again mounts nothing, so there'd be no disk to wait for.
            guard let volume = await attached()[path]?.first(where: isBrowsable) else { return }
            guard let index = waiting.firstIndex(where: { $0.until == ticket }) else { return }   // its disk appeared meanwhile
            waiting.remove(at: index)
            show(volume)
        }
    }

    public static func startWatching() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { volumeMounted(volume) }
        }
    }

    static func volumeMounted(_ volume: URL) {
        guard isBrowsable(volume) else { return }
        waiting.removeAll { $0.until < Date() }
        if !waiting.isEmpty {
            NSApplication.shared.activate()   // the mounter may have come to the front meanwhile
            waiting.removeFirst().show(volume)
            return
        }
        // Not opened here. Finder would show it; while Foray stands in for Finder, Foray does.
        // Only disk images, though: a USB drive or a server just turns up in the sidebar.
        guard FinderTakeover.isEnabled else { return }
        Task { @MainActor in
            let path = volume.standardizedFileURL.path
            let images = await attached()
            if images.values.contains(where: { $0.contains { $0.standardizedFileURL.path == path } }) { showInNewWindow(volume) }
        }
    }

    /// `hdiutil info -plist`: every attached image and its mount points.
    nonisolated static func hdiutilInfo() -> [String: [URL]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(hdiutilInfo: data)
    }

    nonisolated static func parse(hdiutilInfo data: Data) -> [String: [URL]] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var out: [String: [URL]] = [:]
        for image in images {
            guard let path = image["image-path"] as? String else { continue }
            let mounts = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            if !mounts.isEmpty { out[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = mounts.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        }
        return out
    }
}
