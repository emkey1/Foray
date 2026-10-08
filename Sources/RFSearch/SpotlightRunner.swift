import Foundation

/// Runs an NSMetadataQuery on a private operation queue and streams result paths: the initial
/// gathering in batches, then live additions and removals.
final class SpotlightRunner: @unchecked Sendable {
    enum Event: Sendable {
        case added([String])
        case removed([String])
        case finishedGathering
    }

    private let query = NSMetadataQuery()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private var observers: [NSObjectProtocol] = []
    private var delivered = 0   // results already reported during gathering; queue-confined

    enum Scope: Sendable {
        case folder(URL)
        case localComputer
    }

    /// `queryString` is in Spotlight's metadata query language (see `SpotlightQuery`).
    func run(_ queryString: String, scopes: [Scope]) -> AsyncStream<Event> {
        AsyncStream { continuation in
            queue.addOperation { [self] in
                guard let predicate = NSPredicate(fromMetadataQueryString: queryString) else {
                    return continuation.finish()
                }
                query.predicate = predicate
                query.searchScopes = scopes.map { scope -> Any in
                    switch scope {
                    case .folder(let url): url
                    case .localComputer: NSMetadataQueryLocalComputerScope
                    }
                }
                query.operationQueue = queue
                query.notificationBatchingInterval = 0.1
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: queue) { [self] _ in
                        deliverNew(continuation)
                    },
                    center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue) { [self] _ in
                        deliverNew(continuation)
                        continuation.yield(.finishedGathering)
                    },
                    center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: queue) { note in
                        let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
                        let removed = (note.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem]) ?? []
                        let paths = { (items: [NSMetadataItem]) in items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String } }
                        if !added.isEmpty { continuation.yield(.added(paths(added))) }
                        if !removed.isEmpty { continuation.yield(.removed(paths(removed))) }
                    },
                ]
                if !query.start() { continuation.finish() }
            }
            continuation.onTermination = { [self] _ in stop() }
        }
    }

    /// Results gathered since the last call (during the initial gathering phase).
    private func deliverNew(_ continuation: AsyncStream<Event>.Continuation) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let count = query.resultCount
        guard count > delivered else { return }
        var paths: [String] = []
        paths.reserveCapacity(count - delivered)
        for i in delivered..<count {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(path)
            }
        }
        delivered = count
        continuation.yield(.added(paths))
    }

    private func stop() {
        queue.addOperation { [self] in
            query.stop()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
