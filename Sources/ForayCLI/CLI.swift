import Foundation
import RFFileSystem
import RFModel
import RFOperations
import RFSearch

/// The `foray` command-line tool (DESIGN.md §5.12). Searching, trashing and tagging happen in the
/// tool itself; opening things is handed to the Foray app the tool lives in.
///
/// Everything it touches from outside (the app, the Trash, the terminal) comes in through
/// `Environment`, so tests run it without launching anything.
public struct CLI: Sendable {
    public struct Environment: Sendable {
        public var currentDirectory: URL
        /// Opens file or `foray://` URLs in the Foray app. Returns an error message, or nil.
        public var openInApp: @Sendable ([URL]) async -> String?
        public var trash: TrashFunction
        /// The app's URL scheme (`foray`; `foray-dev` for test builds).
        public var scheme: String
        public var version: String

        public init(currentDirectory: URL, openInApp: @escaping @Sendable ([URL]) async -> String?, trash: @escaping TrashFunction,
                    scheme: String = "foray", version: String = "dev") {
            self.currentDirectory = currentDirectory
            self.openInApp = openInApp
            self.trash = trash
            self.scheme = scheme
            self.version = version
        }
    }

    public struct Output: Sendable, Equatable {
        public var status: Int32 = 0
        public var out = ""
        public var err = ""
    }

    public static let usage = """
    usage: foray [path ...]                    Open folders in Foray (no path: the current directory).
                                               Files are shown selected in their folder.
           foray reveal path ...               Show items selected in their enclosing folder.
           foray search [options] query ...    Print the paths of matching items.
               -i, --in dir                    Search this folder and its subfolders (default: the
                                               current directory).
               -m, --mac                       Search the whole Mac.
               -c, --contents                  Also match text inside files (default: names only).
               -n, --limit count               Stop after this many items.
               -0, --print0                    Separate paths with NUL instead of newlines (for xargs -0).
               -o, --open                      Show the search in Foray instead of printing.
           foray trash path ...                Move items to the Trash (Put Back works).
           foray tag [-a tag] [-r tag] path ...
                                               Add (-a) and remove (-r) tags; with neither, list them.
           foray --version | --help

    Queries use Foray's search syntax, for example:  foray search report kind:pdf modified:>2026-01-01
    """

    let env: Environment

    public init(_ env: Environment) { self.env = env }

    /// Runs one invocation. `arguments` excludes the program name.
    public func run(_ arguments: [String]) async -> Output {
        var args = arguments[...]
        switch args.first {
        case "--help", "-h", "help":
            return Output(out: Self.usage + "\n")
        case "--version", "-v":
            return Output(out: "foray \(env.version)\n")
        case "open":
            args = args.dropFirst()
            return await open(Array(args), reveal: false)
        case "reveal":
            return await open(Array(args.dropFirst()), reveal: true)
        case "search":
            return await search(Array(args.dropFirst()))
        case "trash":
            return trash(Array(args.dropFirst()))
        case "tag":
            return tag(Array(args.dropFirst()))
        default:
            return await open(Array(args), reveal: false)
        }
    }

    // MARK: Paths

    func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: env.currentDirectory).standardizedFileURL
    }

    private func fail(_ message: String, status: Int32 = 1) -> Output {
        Output(status: status, err: "foray: \(message)\n")
    }

    private func usageError(_ message: String) -> Output {
        Output(status: 64, err: "foray: \(message)\n\(Self.usage)\n")
    }

    /// Splits existing paths from missing ones (reported, but the rest still go ahead).
    private func existing(_ paths: [String]) -> (urls: [URL], missing: String) {
        var urls: [URL] = [], missing = ""
        for path in paths {
            let u = url(path)
            if FileManager.default.fileExists(atPath: u.path) { urls.append(u) } else { missing += "foray: \(path): No such file or directory\n" }
        }
        return (urls, missing)
    }

    // MARK: open, reveal

    private func open(_ paths: [String], reveal: Bool) async -> Output {
        if let option = paths.first(where: { $0.hasPrefix("-") && $0 != "-" && !FileManager.default.fileExists(atPath: url($0).path) }) {
            return usageError("unknown option \(option)")
        }
        if reveal && paths.isEmpty { return usageError("reveal needs at least one path") }
        var (urls, missing) = existing(paths.isEmpty ? ["."] : paths)
        guard !urls.isEmpty else { return Output(status: 1, err: missing) }
        if reveal {
            // The app opens folders it's handed; a reveal link shows them selected instead.
            urls = urls.compactMap { link("reveal", ["path": $0.path]) }
        }
        if let problem = await env.openInApp(urls) { return fail(problem) }
        return Output(status: missing.isEmpty ? 0 : 1, err: missing)
    }

    func link(_ host: String, _ items: KeyValuePairs<String, String>) -> URL? {
        var c = URLComponents()
        c.scheme = env.scheme
        c.host = host
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }

    // MARK: search

    private func search(_ arguments: [String]) async -> Output {
        var folder: URL? = env.currentDirectory
        var contents = false, print0 = false, show = false
        var limit: Int?
        var words: [String] = []
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            i += 1
            switch a {
            case "-i", "--in":
                guard i < arguments.count else { return usageError("\(a) needs a folder") }
                folder = url(arguments[i])
                i += 1
            case "-m", "--mac": folder = nil
            case "-c", "--contents": contents = true
            case "-0", "--print0": print0 = true
            case "-o", "--open": show = true
            case "-n", "--limit":
                guard i < arguments.count, let n = Int(arguments[i]), n > 0 else { return usageError("\(a) needs a number") }
                limit = n
                i += 1
            case "--":
                words += arguments[i...]
                i = arguments.count
            default:
                // Queries can start with "-" (exclusions), so only the options above are special.
                words.append(a)
            }
        }
        let text = words.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return usageError("search needs a query") }
        if let folder {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                return fail("\(folder.path): Not a folder")
            }
        }
        if show {
            var items: KeyValuePairs<String, String> = ["q": text]
            if let folder { items = ["q": text, "in": folder.path] }
            guard let link = link("search", items) else { return fail("couldn't build the search link") }
            if let problem = await env.openInApp([link]) { return fail(problem) }
            return Output()
        }
        let query = SearchQuery(text: text, scope: folder.map { .folder($0, recursive: true) } ?? .thisMac,
                                match: contents ? .namesAndContents : .names)
        let status = await SearchEngine.collect(query, limit: limit)
        let paths = status.items.map(\.url.path).sorted()
        var output = Output(status: paths.isEmpty ? 1 : 0)   // like grep: 1 when nothing matched
        output.out = paths.map { $0 + (print0 ? "\0" : "\n") }.joined()
        if status.foldersSkipped > 0 { output.err = "foray: \(status.foldersSkipped) folders couldn't be read\n" }
        return output
    }

    // MARK: trash

    private func trash(_ paths: [String]) -> Output {
        guard !paths.isEmpty else { return usageError("trash needs at least one path") }
        var output = Output()
        for path in paths {
            let u = url(path)
            // lstat, not fileExists: a broken symlink can be trashed too.
            var info = stat()
            guard lstat(u.path, &info) == 0 else {
                output.err += "foray: \(path): No such file or directory\n"
                output.status = 1
                continue
            }
            do {
                _ = try env.trash(u)
            } catch {
                output.err += "foray: \(path): \(error.localizedDescription)\n"
                output.status = 1
            }
        }
        return output
    }

    // MARK: tag

    private func tag(_ arguments: [String]) -> Output {
        var add: [String] = [], remove: [String] = [], paths: [String] = []
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            i += 1
            switch a {
            case "-a", "--add", "-r", "--remove":
                guard i < arguments.count else { return usageError("\(a) needs a tag name") }
                if a == "-a" || a == "--add" { add.append(arguments[i]) } else { remove.append(arguments[i]) }
                i += 1
            case "--":
                paths += arguments[i...]
                i = arguments.count
            default:
                paths.append(a)
            }
        }
        guard !paths.isEmpty else { return usageError("tag needs at least one path") }
        let (urls, missing) = existing(paths)
        var output = Output(status: missing.isEmpty ? 0 : 1, err: missing)
        for u in urls {
            let current = Tags.names(at: u)
            if add.isEmpty && remove.isEmpty {
                output.out += (urls.count > 1 ? "\(u.path): " : "") + current.joined(separator: ", ") + "\n"
                continue
            }
            let removing = Set(remove.map { $0.lowercased() })
            var names = current.filter { !removing.contains($0.lowercased()) }
            for name in add where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            guard names != current else { continue }
            let code = Tags.write(names, to: u)
            if code != 0 {
                output.err += "foray: \(u.path): \(String(cString: strerror(code)))\n"
                output.status = 1
            }
        }
        return output
    }
}
