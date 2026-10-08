import Foundation

/// Batch rename rules (DESIGN.md §4.4, I9): Finder's Replace Text, Add Text and Format, plus
/// regular expressions and case changes. Pure: computes new names; the engine renames.
public struct RenameRule: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case replace, add, format, changeCase
        public var title: String {
            switch self {
            case .replace: "Replace Text"
            case .add: "Add Text"
            case .format: "Format"
            case .changeCase: "Change Case"
            }
        }
    }
    public enum Position: String, CaseIterable, Sendable { case before, after }
    public enum NumberStyle: String, CaseIterable, Sendable {
        /// 1, 2, 3
        case index
        /// 00001, 00002 (Finder's counter)
        case counter
        /// The item's modification date and time.
        case date
    }
    public enum Case: String, CaseIterable, Sendable { case lower, upper, title }

    public var mode: Mode = .replace
    // Replace
    public var find = ""
    public var replacement = ""
    public var useRegex = false
    public var caseSensitive = false
    // Add
    public var text = ""
    public var position: Position = .after
    // Format
    public var baseName = "Item"
    public var numberStyle: NumberStyle = .index
    public var startAt = 1
    public var numberPosition: Position = .after
    // Change case
    public var newCase: Case = .lower
    /// Rules apply to the name without its extension unless this is on.
    public var includeExtension = false

    public init() {}

    /// The regex is invalid (shown in the sheet instead of a preview).
    public var regexProblem: String? {
        guard mode == .replace, useRegex, !find.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: find) } catch { return "That regular expression isn't valid." }
        return nil
    }

    /// New names for `items` (name and modification date), in order.
    public func newNames(for items: [(name: String, modified: Date?)]) -> [String] {
        let regex = mode == .replace && useRegex && !find.isEmpty
            ? try? NSRegularExpression(pattern: find, options: caseSensitive ? [] : [.caseInsensitive]) : nil
        let dateFormat = DateFormatter()
        dateFormat.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return items.enumerated().map { i, item in
            let (stem, ext) = includeExtension ? (item.name, nil) : Self.split(item.name)
            let newStem: String
            switch mode {
            case .replace:
                if find.isEmpty {
                    newStem = stem
                } else if let regex {
                    newStem = regex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: replacement)
                } else {
                    newStem = stem.replacingOccurrences(of: find, with: replacement, options: caseSensitive ? [] : [.caseInsensitive])
                }
            case .add:
                newStem = position == .before ? text + stem : stem + text
            case .format:
                let number: String = switch numberStyle {
                case .index: String(startAt + i)
                case .counter: String(format: "%05d", startAt + i)
                case .date: item.modified.map(dateFormat.string(from:)) ?? String(startAt + i)
                }
                newStem = numberPosition == .after ? "\(baseName) \(number)" : "\(number) \(baseName)"
            case .changeCase:
                newStem = switch newCase {
                case .lower: stem.lowercased()
                case .upper: stem.uppercased()
                case .title: stem.capitalized
                }
            }
            return ext.map { "\(newStem).\($0)" } ?? newStem
        }
    }

    /// Splits off the extension the way Finder shows it ("photo.jpg" → "photo", "jpg").
    static func split(_ name: String) -> (String, String?) {
        let (base, ext) = FileNaming.split(name)
        return (base, ext)
    }

    /// Why each new name can't be used (index → reason): empty or invalid, two items getting the
    /// same name, or a name taken by an item that isn't being renamed.
    public static func problems(old: [String], new: [String], existing: Set<String>) -> [Int: String] {
        var out: [Int: String] = [:]
        let renamed = Set(old.map { $0.lowercased() })
        var seen: [String: Int] = [:]
        for (i, name) in new.enumerated() {
            if let p = FileNaming.problem(with: name) { out[i] = p; continue }
            let key = name.lowercased()   // APFS is usually case-insensitive
            if let j = seen[key] {
                out[i] = "Same name as another item"
                out[j] = out[j] ?? "Same name as another item"
            } else {
                seen[key] = i
            }
            if existing.contains(where: { $0.lowercased() == key }) && !renamed.contains(key) {
                out[i] = "An item with this name already exists"
            }
        }
        return out
    }
}
