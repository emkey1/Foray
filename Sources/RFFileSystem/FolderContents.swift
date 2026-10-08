import Foundation
import RFModel
import Synchronization

public enum FolderEvent: Sendable {
    /// Loading is in progress; items so far (cumulative).
    case partial([FileItem])
    /// The full listing, initially or after a change.
    case complete([FileItem])
    case failed(FileSystemError)
}

/// Loads a folder and keeps it current: streams the initial listing, then re-lists after change
/// events. (M1 re-lists the folder on change; 100k entries take ~270 ms. Per-entry re-stat is a
/// later optimization, DESIGN.md §5.4.)
public enum FolderContents {
    public static func observe(
        _ directory: URL, loader: DirectoryLoader = .shared, watcher: DirectoryWatcher = .shared
    ) -> AsyncStream<FolderEvent> {
        AsyncStream { continuation in
            let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            // Subscribing creates and starts an FSEvents stream, which talks to fseventsd and can
            // stall when it's busy. Do it in the background task, never on the caller's (main) thread.
            let token = Mutex<DirectoryWatcher.Token?>(nil)

            let task = Task.detached(priority: .userInitiated) {
                let t = watcher.subscribe(directory) { changes.continuation.yield() }
                token.withLock { $0 = t }
                if Task.isCancelled { return watcher.unsubscribe(t) }
                func list(streaming: Bool) async {
                    var items: [FileItem] = []
                    do {
                        for try await batch in loader.load(directory) {
                            items.append(contentsOf: batch)
                            if streaming { continuation.yield(.partial(items)) }
                        }
                        continuation.yield(.complete(items))
                    } catch let error as FileSystemError {
                        continuation.yield(.failed(error))
                    } catch {
                        continuation.yield(.failed(FileSystemError(code: EIO, path: directory.path)))
                    }
                }
                await list(streaming: true)
                for await _ in changes.stream {
                    if Task.isCancelled { break }
                    await list(streaming: false)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                changes.continuation.finish()
                if let t = token.withLock({ $0.take() }) { watcher.unsubscribe(t) }
            }
        }
    }
}
