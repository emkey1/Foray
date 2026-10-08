import Foundation

/// Temporary folders for tests. Suite instances aren't always released (so `deinit` cleanup
/// doesn't always run); each new folder also sweeps away this prefix's folders from earlier runs.
enum TestDirs {
    static func make(_ prefix: String) -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-600)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            for name in names where name.hasPrefix("rf-\(prefix)-") {
                let url = tmp.appendingPathComponent(name)
                if let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate, date < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        return tmp.appendingPathComponent("rf-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
