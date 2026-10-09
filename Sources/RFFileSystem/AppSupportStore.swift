import Foundation

/// Small Codable documents in ~/Library/Application Support/Foray. M1 stand-in for the
/// SQLite store (DESIGN.md §5.10); callers depend only on load/save.
public struct AppSupportStore: Sendable {
    public let directory: URL

    /// The app's store. Inside a test process it's a private temporary folder instead, so a test
    /// that forgets to substitute its own store can't touch the user's settings.
    public static let shared: AppSupportStore = {
        if TestEnvironment.isActive {
            return AppSupportStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rf-test-appsupport-\(getpid())", isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // "Foray", or "Foray Dev" for test builds (their own settings, sidebar and history).
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Foray"
        let dir = support.appendingPathComponent(name, isDirectory: true)
        // Foray was called RealFinder during development: take over its folder the first time.
        let legacy = support.appendingPathComponent("RealFinder", isDirectory: true)
        if name == "Foray", !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        return AppSupportStore(directory: dir)
    }()

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
            NSLog("Foray: couldn't save \(name): \(error)")
        }
    }
}

/// Whether this process is a test run (`swift test`), for safety defaults.
public enum TestEnvironment {
    public static let isActive: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name.contains("xctest") || name.contains("swiftpm-testing-helper") || NSClassFromString("XCTestCase") != nil
    }()
}
