import Darwin
import Foundation

/// When a file was last opened: the `com.apple.lastuseddate#PS` xattr (a `timespec`), which is
/// where `kMDItemLastUsedDate` comes from. Reading it skips a Spotlight round trip.
public enum LastOpened {
    public static let attribute = "com.apple.lastuseddate#PS"

    public static func read(_ url: URL) -> Date? {
        var ts = timespec()
        let n = withUnsafeMutableBytes(of: &ts) { buf in
            getxattr(url.path, attribute, buf.baseAddress, buf.count, 0, XATTR_NOFOLLOW)
        }
        guard n == MemoryLayout<timespec>.size, ts.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }

    /// Writes the attribute (tests; apps opening files set it through LaunchServices).
    public static func write(_ date: Date, to url: URL) -> Bool {
        var ts = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        return withUnsafeBytes(of: &ts) { buf in
            setxattr(url.path, attribute, buf.baseAddress, buf.count, 0, XATTR_NOFOLLOW) == 0
        }
    }
}
