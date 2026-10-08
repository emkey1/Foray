import Foundation
import RFModel

/// Folder totals for "Calculate all sizes" (DESIGN.md §5.8). Two walks at a time; results are
/// cached for the session and reused while the folder's modification date is unchanged and the
/// result is under five minutes old (changes deep inside don't touch the folder's own date).
public actor FolderSizes {
    public static let shared = FolderSizes()

    private struct Entry {
        var size: Int64
        var modified: Date?
        var at: Date
    }
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<Int64?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public static let maxAge: TimeInterval = 300

    public func cached(_ item: FileItem) -> Int64? {
        guard let e = cache[item.url.path], e.modified == item.modified, Date().timeIntervalSince(e.at) < Self.maxAge else { return nil }
        return e.size
    }

    /// The folder's total logical size (everything inside, hidden items included), or nil if cancelled.
    public func size(of item: FileItem) async -> Int64? {
        if let hit = cached(item) { return hit }
        let path = item.url.path
        if let task = inFlight[path] { return await task.value }
        let task = Task<Int64?, Never> {
            await acquire()
            defer { release() }
            if Task.isCancelled { return nil }
            var total: Int64 = 0
            for await event in TreeWalker.walk(item.url, options: .init(includeHidden: true, includePackageContents: true)) {
                if Task.isCancelled { return nil }
                if case .items(let items) = event {
                    for i in items where !i.flags.contains(.directory) { total += i.size ?? 0 }
                }
            }
            return total
        }
        inFlight[path] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight[path] = nil
        if let result { cache[path] = Entry(size: result, modified: item.modified, at: Date()) }
        return result
    }

    public func invalidate(_ url: URL) { cache[url.path] = nil }

    private func acquire() async {
        if running < 2 {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}
