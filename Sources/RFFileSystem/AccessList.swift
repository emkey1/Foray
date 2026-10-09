import CFastFS
import Darwin
import Foundation

/// One access-list (ACL) entry, in the text form macOS uses (`ls -le`, `acl_to_text`):
/// `group:<UUID>:staff:20:allow,file_inherit:read,write`.
public struct AccessEntry: Hashable, Sendable {
    public enum Tag: String, Sendable { case user, group }
    /// Finder's privilege levels; anything else is shown as Custom and left as it is.
    public enum Level: String, CaseIterable, Sendable { case readWrite, readOnly, writeOnly, custom }

    public var tag: Tag
    public var uuid: String
    public var name: String
    public var id: UInt32?
    public var allow: Bool
    public var flags: [String]
    public var permissions: Set<String>

    public var isInherited: Bool { flags.contains("inherited") }

    public var level: Level {
        guard allow else { return .custom }
        let read = permissions.contains("read"), write = permissions.contains("write")
        return read && write ? .readWrite : read ? .readOnly : write ? .writeOnly : .custom
    }

    /// Finder's permission sets for each level (folders also pass them on to new items inside).
    public static func permissions(for level: Level, isDirectory: Bool) -> (Set<String>, [String]) {
        let inherit = isDirectory ? ["file_inherit", "directory_inherit"] : []
        switch level {
        case .readWrite:
            return (Set(["read", "write", "append", "readattr", "writeattr", "readextattr", "writeextattr", "readsecurity"])
                .union(isDirectory ? ["execute", "delete_child"] : []), inherit)
        case .readOnly:
            return (Set(["read", "readattr", "readextattr", "readsecurity"]).union(isDirectory ? ["execute"] : []), inherit)
        case .writeOnly:
            return (Set(["write", "append", "writeattr", "writeextattr"]).union(isDirectory ? ["execute"] : []), inherit)
        case .custom:
            return ([], [])
        }
    }

    public init(tag: Tag, uuid: String, name: String, id: UInt32?, allow: Bool, flags: [String], permissions: Set<String>) {
        (self.tag, self.uuid, self.name, self.id, self.allow, self.flags, self.permissions) = (tag, uuid, name, id, allow, flags, permissions)
    }

    /// A new entry for a user or group at a Finder level.
    public static func make(_ tag: Tag, name: String, id: UInt32, level: Level, isDirectory: Bool) -> AccessEntry {
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let ok = tag == .user ? mbr_uid_to_uuid(id, &uuid) == 0 : mbr_gid_to_uuid(id, &uuid) == 0
        let (perms, flags) = permissions(for: level, isDirectory: isDirectory)
        return AccessEntry(tag: tag, uuid: ok ? UUID(uuid: uuid).uuidString : "", name: name, id: id, allow: true,
                           flags: flags, permissions: perms)
    }

    /// The same entry at another level (keeps who it's for).
    public func with(level: Level, isDirectory: Bool) -> AccessEntry {
        var e = self
        (e.permissions, e.flags) = Self.permissions(for: level, isDirectory: isDirectory)
        e.allow = true
        return e
    }

    // Permission and flag order as acl_to_text writes them (any order is accepted when reading).
    static let order = ["read", "write", "execute", "delete", "append", "delete_child", "readattr", "writeattr", "readextattr",
                        "writeextattr", "readsecurity", "writesecurity", "chown"]

    public var line: String {
        let perms = Self.order.filter(permissions.contains) + permissions.subtracting(Self.order).sorted()
        let kind = ([allow ? "allow" : "deny"] + flags).joined(separator: ",")
        return "\(tag.rawValue):\(uuid):\(name):\(id.map(String.init) ?? ""):\(kind):\(perms.joined(separator: ","))"
    }

    init?(line: String) {
        let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 6, let tag = Tag(rawValue: f[0]) else { return nil }
        let kind = f[4].split(separator: ",").map(String.init)
        guard let first = kind.first, first == "allow" || first == "deny" else { return nil }
        self.init(tag: tag, uuid: f[1], name: f[2], id: UInt32(f[3]), allow: first == "allow", flags: Array(kind.dropFirst()),
                  permissions: Set(f[5].split(separator: ",").map(String.init)))
    }
}

/// Reading and writing a file's access list (DESIGN.md §5.8).
public enum AccessList {
    /// The list as text ("" when there is none).
    public static func text(_ url: URL) -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return "" }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var len = 0
        guard let t = acl_to_text(acl, &len) else { return "" }
        defer { acl_free(t) }
        return String(cString: t)
    }

    public static func entries(_ text: String) -> [AccessEntry] {
        text.split(separator: "\n").compactMap { $0.hasPrefix("!#") ? nil : AccessEntry(line: String($0)) }
    }

    public static func text(for entries: [AccessEntry]) -> String {
        entries.isEmpty ? "" : (["!#acl 1"] + entries.map(\.line)).joined(separator: "\n") + "\n"
    }

    /// Replaces the list ("" removes it). Returns 0 or an errno.
    public static func write(_ text: String, to url: URL) -> Int32 {
        let acl = text.isEmpty ? acl_init(0) : acl_from_text(text)
        guard let acl else { return EINVAL }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return acl_set_link_np(url.path, ACL_TYPE_EXTENDED, acl) == 0 ? 0 : errno
    }
}

/// Stationery Pad: a Finder flag in the item's FinderInfo. Opening stationery gives you a copy.
public enum Stationery {
    static let attribute = "com.apple.FinderInfo"
    static let flag: UInt16 = 0x0800   // kIsStationery, in the big-endian finderFlags at byte 8

    public static func isSet(_ url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(url.path, attribute, &info, 32, 0, XATTR_NOFOLLOW) == 32 else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & flag != 0
    }

    public static func set(_ on: Bool, _ url: URL) -> Int32 {
        var info = [UInt8](repeating: 0, count: 32)
        _ = getxattr(url.path, attribute, &info, 32, 0, XATTR_NOFOLLOW)
        var flags = UInt16(info[8]) << 8 | UInt16(info[9])
        flags = on ? flags | flag : flags & ~flag
        info[8] = UInt8(flags >> 8)
        info[9] = UInt8(flags & 0xff)
        if info.allSatisfy({ $0 == 0 }) {
            return removexattr(url.path, attribute, XATTR_NOFOLLOW) == 0 || errno == ENOATTR ? 0 : errno
        }
        return setxattr(url.path, attribute, info, 32, 0, XATTR_NOFOLLOW) == 0 ? 0 : errno
    }
}
