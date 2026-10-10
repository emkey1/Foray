import Darwin
import Foundation
import RFFileSystem
import RFModel

// Administrator file operations (DESIGN.md §5.11).
//
// When a file primitive fails for lack of permission, the engine can run that one primitive again
// through the privileged helper: a root launchd daemon inside the app bundle, off until the user
// turns it on in Settings › Advanced. The helper accepts only the operations below, on explicit
// paths, from Foray itself (checked by code signature), and only with an administrator's
// authorization for each job. It never runs commands.

/// One primitive the helper will do. Paths are absolute.
public enum PrivilegedOperation: Codable, Sendable, Equatable {
    /// Move within a volume. Never replaces an existing item.
    case rename(from: String, to: String)
    /// A new folder, owned by the user who asked.
    case makeDirectory(path: String, mode: UInt16)
    /// Copy one file or symlink (not followed) with its metadata. The copy belongs to the user who asked.
    case copyFile(from: String, to: String)
    /// Dates, permissions, flags and extended attributes of a copied folder.
    case copyDirectoryMetadata(from: String, to: String)
    /// Delete a file, or a folder and everything in it.
    case remove(path: String)
    /// Permission bits, access list and the Locked flag (the only attributes that need an administrator).
    case writeAttributes(path: String, attributes: ItemAttributes)

    var paths: [String] {
        switch self {
        case .rename(let a, let b), .copyFile(let a, let b), .copyDirectoryMetadata(let a, let b): [a, b]
        case .makeDirectory(let p, _), .remove(let p), .writeAttributes(let p, _): [p]
        }
    }
}

/// Something that can carry out privileged primitives: the helper connection, or a test double.
public protocol PrivilegedFileOps: Sendable {
    /// Returns 0 or an errno.
    func perform(_ operation: PrivilegedOperation) -> Int32
}

/// Asked (off the main thread; it may block while the user authenticates) the first time a job
/// hits a permission error. Returns nil if administrator access isn't available or was declined.
public typealias ElevationProvider = @Sendable (_ jobTitle: String) -> PrivilegedFileOps?

/// What the helper does with a request. Lives here, not in the helper executable, so it's tested
/// like the rest of the engine (as an ordinary user, in temporary folders).
public enum PrivilegedExecutor {
    /// Paths must be absolute and already resolved: no "..", ".", empty or doubled components.
    static func isAcceptable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX) else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Runs one operation. `owner` is the user who asked (taken from the connection, never from
    /// the request): things the helper creates belong to them, as with Finder's authenticated copies.
    public static func perform(_ operation: PrivilegedOperation, owner: uid_t) -> Int32 {
        guard operation.paths.allSatisfy(isAcceptable) else { return EINVAL }
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        switch operation {
        case .rename(let from, let to):
            return FileOps.rename(url(from), to: url(to))
        case .makeDirectory(let path, let mode):
            let rc = FileOps.makeDirectory(url(path), mode: mode_t(mode & 0o777))
            return rc == 0 ? own(path, owner) : rc
        case .copyFile(let from, let to):
            guard let st = FileOps.lstat(url(from)) else { return errno }
            guard !FileOps.isDirectory(st) else { return EISDIR }
            let rc = FileOps.copyFile(url(from), to: url(to), progress: nil)
            return rc == 0 ? own(to, owner) : rc
        case .copyDirectoryMetadata(let from, let to):
            return FileOps.copyDirectoryMetadata(url(from), to: url(to))
        case .remove(let path):
            return FileOps.remove(url(path))
        case .writeAttributes(let path, let attributes):
            // Only what needs an administrator; comments and the like go through the app.
            let allowed = ItemAttributes(locked: attributes.locked, permissions: attributes.permissions, accessList: attributes.accessList)
            return ItemAttributes.write(allowed, to: url(path))
        }
    }

    /// The group is left as created (inherited from the enclosing folder).
    private static func own(_ path: String, _ owner: uid_t) -> Int32 {
        lchown(path, owner, gid_t.max) == 0 ? 0 : errno
    }
}

/// The engine's file primitives, with one retry as an administrator when permission is missing.
/// One per job: the user is asked at most once, and every later primitive in the job reuses the answer.
final class ElevatingFileOps: @unchecked Sendable {
    private let provider: ElevationProvider?
    private let jobTitle: String
    private let lock = NSLock()
    private var asked = false
    private var granted: PrivilegedFileOps?
    /// Where an item that can't be trashed normally goes (the user's Trash on its volume).
    var trashFolder: @Sendable (URL) -> URL? = ElevatingFileOps.userTrash

    init(provider: ElevationProvider?, jobTitle: String) {
        self.provider = provider
        self.jobTitle = jobTitle
    }

    /// The helper session for this job; asks the first time.
    private func privileged() -> PrivilegedFileOps? {
        lock.withLock {
            if !asked {
                asked = true
                granted = provider?(jobTitle)
            }
            return granted
        }
    }

    /// Whether `rc` on `item` is something an administrator can get past. EACCES is ordinary file
    /// permissions. EPERM is usually something else (a locked item, privacy protection, system
    /// integrity protection), which root can't override either; it's ours only for a sticky folder
    /// (deleting or moving someone else's item) or changing an item we don't own.
    private func isPermissionProblem(_ rc: Int32, _ item: URL, changingAttributes: Bool = false) -> Bool {
        if rc == EACCES { return true }
        guard rc == EPERM else { return false }
        if let st = FileOps.lstat(item) {
            if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return false }
            if changingAttributes { return st.st_uid != getuid() }
        }
        guard let parent = FileOps.lstat(item.deletingLastPathComponent()) else { return false }
        return parent.st_mode & S_ISVTX != 0
    }

    private func retry(_ rc: Int32, on item: URL, changingAttributes: Bool = false, _ operation: @autoclosure () -> PrivilegedOperation) -> Int32 {
        guard provider != nil, isPermissionProblem(rc, item, changingAttributes: changingAttributes), let helper = privileged() else { return rc }
        return helper.perform(operation())
    }

    func rename(_ from: URL, to: URL) -> Int32 {
        retry(FileOps.rename(from, to: to), on: from, .rename(from: from.path, to: to.path))
    }

    func makeDirectory(_ url: URL, mode: mode_t = 0o755) -> Int32 {
        retry(FileOps.makeDirectory(url, mode: mode), on: url, .makeDirectory(path: url.path, mode: UInt16(mode)))
    }

    func copyFile(_ from: URL, to: URL, progress: ((Int64) -> Bool)?) -> Int32 {
        retry(FileOps.copyFile(from, to: to, progress: progress), on: to, .copyFile(from: from.path, to: to.path))
    }

    func copyDirectoryMetadata(_ from: URL, to: URL) -> Int32 {
        retry(FileOps.copyDirectoryMetadata(from, to: to), on: to, changingAttributes: true, .copyDirectoryMetadata(from: from.path, to: to.path))
    }

    func remove(_ url: URL) -> Int32 {
        retry(FileOps.remove(url), on: url, .remove(path: url.path))
    }

    /// Removes one of our own temporary copies, as an administrator if that's how it got there.
    func removeTree(_ url: URL) {
        FileOps.removeTree(url)
        if FileOps.exists(url), let helper = lock.withLock({ granted }) { _ = helper.perform(.remove(path: url.path)) }
    }

    func writeAttributes(_ attributes: ItemAttributes, to url: URL) -> Int32 {
        retry(ItemAttributes.write(attributes, to: url), on: url, changingAttributes: true, .writeAttributes(path: url.path, attributes: attributes))
    }

    /// Moves an item to the Trash; without permission, an administrator moves it into the user's
    /// Trash on the same volume instead.
    func trash(_ item: URL, with trashItem: TrashFunction) throws -> URL {
        do {
            return try trashItem(item)
        } catch {
            let rc = Execution.errno(of: error as NSError)
            guard provider != nil, isPermissionProblem(rc, item), let folder = trashFolder(item), let helper = privileged() else { throw error }
            let name = FileNaming.keepBothFreeName(item.lastPathComponent) { FileOps.exists(folder.appendingPathComponent($0)) }
            let destination = folder.appendingPathComponent(name)
            let moved = helper.perform(.rename(from: item.path, to: destination.path))
            guard moved == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(moved)) }
            return destination
        }
    }

    /// The user's Trash on the item's volume, if it exists.
    static func userTrash(for item: URL) -> URL? {
        let home = TrashFolders.home
        var folder = home
        if !FileOps.sameVolume(item, home) {
            guard let volume = (try? item.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
            folder = TrashFolders.folder(onVolume: volume)
        }
        return FileOps.exists(folder) ? folder : nil
    }
}
