import CFastFS
import Darwin
import Foundation

/// Thin, errno-returning wrappers over the syscalls the engine uses. All of them run on a job's
/// own I/O queue, never on the main thread.
enum FileOps {
    static func lstat(_ url: URL) -> stat? {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0 ? st : nil
    }

    static func exists(_ url: URL) -> Bool { lstat(url) != nil }

    static func isDirectory(_ st: stat) -> Bool { st.st_mode & S_IFMT == S_IFDIR }
    static func isSymlink(_ st: stat) -> Bool { st.st_mode & S_IFMT == S_IFLNK }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let x = lstat(a), let y = lstat(b) else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    static func sameVolume(_ item: URL, _ folder: URL) -> Bool {
        guard let x = lstat(item), let y = lstat(folder) else { return false }
        return x.st_dev == y.st_dev
    }

    /// `rename` that never replaces anything (RENAME_EXCL). The one exception is a case-only
    /// rename on a case-insensitive volume, where the "existing" destination is the item itself.
    static func rename(_ from: URL, to: URL) -> Int32 {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let err = errno
        if err == EEXIST, sameFile(from, to), from.path != to.path {
            return Darwin.rename(from.path, to.path) == 0 ? 0 : errno
        }
        // Some filesystems (exFAT, some network volumes) don't support RENAME_EXCL. Check first,
        // then use a plain rename (a tiny race window instead of failing every rename there).
        if err == ENOTSUP || err == EINVAL {
            if exists(to) && !sameFile(from, to) { return EEXIST }
            return Darwin.rename(from.path, to.path) == 0 ? 0 : errno
        }
        return err
    }

    static func makeDirectory(_ url: URL, mode: mode_t = 0o755) -> Int32 {
        mkdir(url.path, mode) == 0 ? 0 : errno
    }

    /// APFS clone of a file or a whole directory tree, metadata included. ENOTSUP/EXDEV when the
    /// volume can't clone.
    static func clone(_ from: URL, to: URL) -> Int32 {
        clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) == 0 ? 0 : errno
    }

    static func copyFile(_ from: URL, to: URL, progress: ((Int64) -> Bool)?) -> Int32 {
        final class Box {
            let progress: ((Int64) -> Bool)?
            init(_ p: ((Int64) -> Bool)?) { progress = p }
        }
        let box = Box(progress)
        return withExtendedLifetime(box) {
            rf_copy_file(from.path, to.path, TestHooks.noClone ? 0 : 1, { copied, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                return (box.progress?(copied) ?? true) ? 0 : 1
            }, Unmanaged.passUnretained(box).toOpaque())
        }
    }

    static func copyDirectoryMetadata(_ from: URL, to: URL) -> Int32 {
        rf_copy_directory_metadata(from.path, to.path)
    }

    /// Recursive delete. Returns 0 or the errno of the first failure.
    static func remove(_ url: URL) -> Int32 {
        removefile(url.path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
    }

    /// Best-effort removal of our own temporary copies, even if their copied metadata made them
    /// read-only or locked.
    static func removeTree(_ url: URL) {
        if remove(url) == 0 { return }
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            unlockForRemoval(url)
            while let rel = enumerator.nextObject() as? String { unlockForRemoval(url.appendingPathComponent(rel)) }
        }
        _ = remove(url)
    }

    private static func unlockForRemoval(_ url: URL) {
        chflags(url.path, 0)
        if let st = lstat(url), isDirectory(st) { chmod(url.path, 0o700) }
    }

    /// Bytes and item count of a tree (planning for progress and free space).
    static func treeSize(_ url: URL) -> (bytes: Int64, items: Int) {
        guard let st = lstat(url) else { return (0, 0) }
        guard isDirectory(st) else { return (Int64(st.st_size), 1) }
        var bytes: Int64 = 0, items = 1
        if let e = FileManager.default.enumerator(atPath: url.path) {
            while let rel = e.nextObject() as? String {
                items += 1
                if let s = lstat(url.appendingPathComponent(rel)), !isDirectory(s) { bytes += Int64(s.st_size) }
            }
        }
        return (bytes, items)
    }

    /// Free space for the pre-flight check. "Available for important usage" (which counts purgeable
    /// space on APFS) reports 0 on some volumes (disk images, external and network disks), which
    /// would block every copy there; the plain statfs figure is always available, so use the larger.
    static func availableCapacity(_ folder: URL) -> Int64? {
        var fs = statfs()
        let plain: Int64? = statfs(folder.path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil
        let important = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        switch (plain, important) {
        case let (p?, i?): return max(p, i)
        case let (p?, nil): return p
        case let (nil, i?): return i > 0 ? i : nil
        default: return nil
        }
    }
}
