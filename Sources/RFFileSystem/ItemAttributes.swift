import Darwin
import Foundation

/// Editable Get Info attributes (DESIGN.md §5.8). A nil field means "leave as is".
public struct ItemAttributes: Sendable, Hashable, Codable {
    public var locked: Bool?
    public var extensionHidden: Bool?
    /// The permission bits (`mode & 0o777`).
    public var permissions: UInt16?
    public var comment: String?
    public var stationery: Bool?
    /// The access list in text form (`AccessList`); "" for none.
    public var accessList: String?

    public init(locked: Bool? = nil, extensionHidden: Bool? = nil, permissions: UInt16? = nil, comment: String? = nil,
                stationery: Bool? = nil, accessList: String? = nil) {
        self.locked = locked
        self.extensionHidden = extensionHidden
        self.permissions = permissions
        self.comment = comment
        self.stationery = stationery
        self.accessList = accessList
    }

    /// The current values of the fields set in `fields`.
    public static func read(_ url: URL, fields: ItemAttributes) -> ItemAttributes {
        var out = ItemAttributes()
        var st = stat()
        let ok = lstat(url.path, &st) == 0
        if fields.locked != nil { out.locked = ok && st.st_flags & UInt32(UF_IMMUTABLE) != 0 }
        if fields.permissions != nil { out.permissions = ok ? UInt16(st.st_mode & 0o777) : nil }
        if fields.extensionHidden != nil { out.extensionHidden = (try? url.resourceValues(forKeys: [.hasHiddenExtensionKey]))?.hasHiddenExtension ?? false }
        if fields.comment != nil { out.comment = Comments.read(url) }
        if fields.stationery != nil { out.stationery = Stationery.isSet(url) }
        if fields.accessList != nil { out.accessList = AccessList.text(url) }
        return out
    }

    /// Applies the set fields. Unlocks first and locks last, since a locked item can't be changed.
    /// Returns 0 or an errno.
    public static func write(_ a: ItemAttributes, to url: URL) -> Int32 {
        var url = url
        if a.locked == false, let rc = setLocked(false, url), rc != 0 { return rc }
        if let p = a.permissions, chmod(url.path, mode_t(p)) != 0 { return errno }
        if let hidden = a.extensionHidden {
            var v = URLResourceValues()
            v.hasHiddenExtension = hidden
            do { try url.setResourceValues(v) } catch { return EIO }
        }
        if let c = a.comment, let rc = Comments.write(c, to: url).errno, rc != 0 { return rc }
        if let s = a.stationery { let rc = Stationery.set(s, url); if rc != 0 { return rc } }
        if let acl = a.accessList { let rc = AccessList.write(acl, to: url); if rc != 0 { return rc } }
        if a.locked == true, let rc = setLocked(true, url), rc != 0 { return rc }
        return 0
    }

    private static func setLocked(_ locked: Bool, _ url: URL) -> Int32? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return errno }
        let flags = locked ? st.st_flags | UInt32(UF_IMMUTABLE) : st.st_flags & ~UInt32(UF_IMMUTABLE)
        return lchflags(url.path, flags) == 0 ? 0 : errno
    }
}

/// Spotlight comments (M0 S6). Finder shows a comment only if it set it itself, so writes go
/// through Finder by Apple Event (asking for the Automation permission once) as well as to the
/// `kMDItemFinderComment` xattr, which Spotlight reads.
public enum Comments {
    public static let attribute = "com.apple.metadata:kMDItemFinderComment"
    /// Tests turn off the Apple Event so Finder isn't involved.
    nonisolated(unsafe) public static var tellFinder = true

    public static func read(_ url: URL) -> String {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return "" }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? String) ?? ""
    }

    public struct WriteResult: Sendable {
        public var errno: Int32?
        /// Finder took the comment (false if Automation was declined or Finder isn't running).
        public var finderUpdated: Bool
    }

    public static func write(_ comment: String, to url: URL) -> WriteResult {
        var finder = false
        if tellFinder { finder = tellFinderToSet(comment, url) }
        // Finder writes the xattr too when it accepts the comment; write it either way.
        let rc: Int32
        if comment.isEmpty {
            rc = removexattr(url.path, attribute, XATTR_NOFOLLOW) == 0 || errno == ENOATTR ? 0 : errno
        } else if let data = try? PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0) {
            rc = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) } == 0 ? 0 : errno
        } else {
            rc = EINVAL
        }
        return WriteResult(errno: rc, finderUpdated: finder)
    }

    private static func tellFinderToSet(_ comment: String, _ url: URL) -> Bool {
        let script = """
        on run argv
            tell application "Finder" to set comment of (POSIX file (item 1 of argv) as alias) to (item 2 of argv)
        end run
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, url.path, comment]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }
}
