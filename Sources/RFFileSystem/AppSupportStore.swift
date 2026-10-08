import Foundation

/// Small Codable documents in ~/Library/Application Support/RealFinder. M1 stand-in for the
/// SQLite store (DESIGN.md §5.10); callers depend only on load/save.
public struct AppSupportStore: Sendable {
    public let directory: URL

    public static let shared = AppSupportStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RealFinder", isDirectory: true))

    public init(directory: URL) { self.directory = directory }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes atomically; failures are logged, not thrown (settings are best-effort).
    public func save<T: Encodable>(_ value: T, to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("RealFinder: couldn't save \(name): \(error)")
        }
    }
}
