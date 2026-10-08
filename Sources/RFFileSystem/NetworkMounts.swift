import Foundation
import NetFS

/// Connect to Server (DESIGN.md §5.9). NetFS mounts the share; the system's own dialog asks for a
/// name and password (and offers the Keychain), so RealFinder never sees credentials.
public enum NetworkMounts {
    public struct Failure: Error, LocalizedError, Sendable {
        public let status: Int32
        public var errorDescription: String? {
            switch status {
            case ECANCELED, -128: "Connecting was cancelled."
            case ENOENT, EHOSTUNREACH, ETIMEDOUT, ENETUNREACH: "The server can't be found or isn't responding."
            case EAUTH, EACCES, EPERM: "The name or password wasn't accepted."
            default: "The server couldn't be connected to (\(status))."
            }
        }
    }

    /// "server", "server/share" or "smb://server/share" → a URL NetFS accepts (SMB when no scheme).
    public static func normalize(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "smb://" + s }
        guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s),
              let scheme = url.scheme?.lowercased(), ["smb", "afp", "nfs", "ftp", "http", "https", "webdav", "cifs", "vnc"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// A Bonjour SMB service as a URL (the form Finder uses: "smb://Name._smb._tcp.local").
    public static func url(forSMBService name: String) -> URL? {
        let host = (name + "._smb._tcp.local").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
        return URL(string: "smb://" + host)
    }

    /// Mounts `url` (asking for credentials or a share if needed) and returns the mount point.
    @MainActor
    public static func mount(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let open = NSMutableDictionary()
            open["UIOption"] = "AllowUI"   // kNAUIOptionKey / kNAUIOptionAllowUI (macros, not imported)
            // Resume exactly once, whether NetFS fails up front or reports later.
            let once = Once(continuation)
            var request: AsyncRequestID?
            let rc = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &request, .main) { status, _, mountpoints in
                let paths = (mountpoints as? [String]) ?? []
                if status == 0, let first = paths.first {
                    once.resume(.success(URL(fileURLWithPath: first, isDirectory: true)))
                } else {
                    once.resume(.failure(Failure(status: status == 0 ? ENOENT : status)))
                }
            }
            if rc != 0 { once.resume(.failure(Failure(status: rc))) }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<URL, Error>) { continuation = c }
        func resume(_ result: Result<URL, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}
