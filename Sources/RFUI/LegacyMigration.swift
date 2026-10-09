import Foundation

/// Foray was called RealFinder during development. On first launch, adopt its preferences
/// (settings, window frames, toolbar) so nothing resets. Its Application Support folder is moved
/// by `AppSupportStore` (RFFileSystem).
public enum LegacyMigration {
    static let oldDomain = "local.realfinder.RealFinder"
    static let doneKey = "MigratedFromRealFinder"

    public static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey), Bundle.main.bundleIdentifier?.hasSuffix(".dev") != true else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
