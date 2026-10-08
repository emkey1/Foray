import Foundation
import RFFileSystem
import RFModel

/// What a running search has found so far.
public struct SearchStatus: Sendable {
    public var items: [FileItem] = []
    public var spotlightRunning = false
    public var crawlRunning = false
    public var foldersScanned = 0
    public var foldersSkipped = 0
    public var isRunning: Bool { spotlightRunning || crawlRunning }
}

/// Plans and runs a search (DESIGN.md §5.6):
/// - folder scope: Spotlight (fast first results) and a crawl (complete, authoritative) in parallel;
/// - This Mac: Spotlight (or a crawl of "/" for queries Spotlight can't express);
/// - folder scope without subfolders: a filter of the folder's listing.
/// Every hit is re-statted by us and re-checked with `QueryMatcher`, so attributes are consistent
/// whichever backend found it and stale Spotlight hits are dropped.
public enum SearchEngine {
    public static func run(_ query: SearchQuery, kinds: KindCatalog = .shared) -> AsyncStream<SearchStatus> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Search(query: query, kinds: kinds, continuation: continuation).run()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor Search {
    let query: SearchQuery
    let matcher: QueryMatcher
    let continuation: AsyncStream<SearchStatus>.Continuation
    let includeHidden: Bool
    let needsTags: Bool

    private var byID: [FileID: FileItem] = [:]
    private var idByPath: [String: FileID] = [:]
    private var status = SearchStatus()
    private var dirty = false

    init(query: SearchQuery, kinds: KindCatalog, continuation: AsyncStream<SearchStatus>.Continuation) {
        self.query = query
        self.matcher = QueryMatcher(query, kinds: kinds)
        self.continuation = continuation
        self.includeHidden = query.includeHidden
        self.needsTags = query.parsed.hasTagTerms
    }

    func run() async {
        if query.isEmpty {
            continuation.yield(status)
            continuation.finish()
            return
        }
        let spotlight = SpotlightQuery.string(for: query)
        switch query.scope {
        case .folder(let url, recursive: false):
            await filterListing(url)
            publish()
            continuation.finish()
            return
        case .folder(let url, recursive: true):
            status.spotlightRunning = spotlight != nil
            status.crawlRunning = true
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.publisher() }
                if let spotlight { group.addTask { await self.runSpotlight(spotlight, scopes: [.folder(url)]) } }
                group.addTask { await self.runCrawl(url) }
            }
        case .thisMac:
            if let spotlight {
                status.spotlightRunning = true
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.publisher() }
                    group.addTask { await self.runSpotlight(spotlight, scopes: [.localComputer]) }
                }
            } else {
                status.crawlRunning = true
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.publisher() }
                    group.addTask { await self.runCrawl(URL(fileURLWithPath: "/")) }
                }
            }
        }
        continuation.finish()
    }

    // MARK: Publishing

    /// Emits the merged results at most every 100 ms while anything changed. Ends when the search
    /// is cancelled or (with no live Spotlight query) when both backends are done.
    private func publisher() async {
        while !Task.isCancelled {
            if dirty { publish() }
            if !status.isRunning && !dirty && !liveSpotlight { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private var liveSpotlight = false

    private func publish() {
        dirty = false
        status.items = Array(byID.values)
        continuation.yield(status)
    }

    private func add(_ items: [FileItem], fromSpotlight: Bool) {
        for item in items where accept(item, fromSpotlight: fromSpotlight) {
            byID[item.id] = item
            idByPath[item.url.path] = item.id
            dirty = true
        }
    }

    private func remove(paths: [String]) {
        for path in paths {
            if let id = idByPath.removeValue(forKey: path) {
                byID[id] = nil
                dirty = true
            }
        }
    }

    private func accept(_ item: FileItem, fromSpotlight: Bool) -> Bool {
        if !includeHidden {
            if item.flags.contains(.hidden) { return false }
            // Spotlight can return items inside hidden folders; crawls never descend into them.
            if fromSpotlight && item.url.pathComponents.contains(where: { $0.hasPrefix(".") }) { return false }
        }
        let tags = needsTags ? Tags.names(at: item.url) : []
        return matcher.matches(item, tags: tags, contentMatches: fromSpotlight)
    }

    // MARK: Backends

    private func runSpotlight(_ queryString: String, scopes: [SpotlightRunner.Scope]) async {
        // Spotlight reports canonical paths (/private/var/…); show them the way the user's scope
        // spells them (/var/…), matching the crawl's results.
        var respell: (String) -> String = { $0 }
        if case .folder(let root) = scopes.first {
            let canonical = DirectoryWatcher.canonicalPath(root.path)
            let given = root.standardizedFileURL.path
            if canonical != given {
                respell = { $0.hasPrefix(canonical + "/") ? given + $0.dropFirst(canonical.count) : $0 }
            }
        }
        let runner = SpotlightRunner()
        for await event in runner.run(queryString, scopes: scopes) {
            if Task.isCancelled { break }
            switch event {
            case .added(let paths):
                let items = await Self.stat(paths.map(respell))
                add(items, fromSpotlight: true)
            case .removed(let paths):
                remove(paths: paths.map(respell))
            case .finishedGathering:
                status.spotlightRunning = false
                liveSpotlight = true   // keeps delivering live updates until cancelled
                dirty = true
            }
        }
        status.spotlightRunning = false
    }

    private func runCrawl(_ root: URL) async {
        let fragments = query.parsed.requiredNameFragments
        let globs = fragments.filter { $0.contains("*") || $0.contains("?") }.compactMap(QueryMatcher.glob)
        let plain = fragments.filter { !($0.contains("*") || $0.contains("?")) }
        let options = TreeWalker.Options(includeHidden: includeHidden)
        let filter: @Sendable (String) -> Bool = { name in
            for p in plain where name.range(of: p, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
            for g in globs {
                let folded = name.folding(options: [.diacriticInsensitive], locale: nil)
                if g.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) == nil { return false }
            }
            return true
        }
        for await event in TreeWalker.walk(root, options: options, nameFilter: filter) {
            if Task.isCancelled { break }
            switch event {
            case .items(let items): add(items, fromSpotlight: false)
            case .progress(let p):
                status.foldersScanned = p.foldersScanned
                status.foldersSkipped = p.foldersSkipped
                dirty = true
            }
        }
        status.crawlRunning = false
        dirty = true
    }

    private func filterListing(_ url: URL) async {
        let items = (try? await DirectoryLoader.shared.loadAll(url)) ?? []
        add(items, fromSpotlight: false)
    }

    /// Re-stats Spotlight hits in parallel (they may be stale or deleted).
    private static func stat(_ paths: [String]) async -> [FileItem] {
        await withTaskGroup(of: [FileItem].self) { group in
            let chunk = max(64, paths.count / 8)
            for start in stride(from: 0, to: paths.count, by: chunk) {
                let slice = Array(paths[start..<min(paths.count, start + chunk)])
                group.addTask { slice.compactMap { DirectoryLoader.shared.stat(URL(fileURLWithPath: $0)) } }
            }
            var all: [FileItem] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
    }
}
