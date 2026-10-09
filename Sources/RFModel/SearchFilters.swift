import Foundation

/// The search criteria editor's model (DESIGN.md §4.6): filters described in words, and filters
/// built from menu choices. It reads and writes the same filter text the search field shows, so
/// typing and clicking stay in step.
public enum SearchFilters {
    public enum Field: String, CaseIterable, Sendable {
        case kind, name, ext, size, modified, created, added, opened, tag, content, hidden
        public var title: String {
            switch self {
            case .kind: "Kind"
            case .name: "Name"
            case .ext: "Extension"
            case .size: "Size"
            case .modified: "Date Modified"
            case .created: "Date Created"
            case .added: "Date Added"
            case .opened: "Last Opened"
            case .tag: "Tag"
            case .content: "Contents"
            case .hidden: "Hidden Files"
            }
        }
        public var isDate: Bool { [.modified, .created, .added, .opened].contains(self) }
    }

    public enum SizeComparison: String, CaseIterable, Sendable { case larger, smaller }
    public enum SizeUnit: String, CaseIterable, Sendable { case KB, MB, GB }
    public enum DateComparison: String, CaseIterable, Sendable {
        case withinLast, olderThan, inYear, today, yesterday
        public var title: String {
            switch self {
            case .withinLast: "within the last"
            case .olderThan: "more than … ago"
            case .inYear: "in the year"
            case .today: "today"
            case .yesterday: "yesterday"
            }
        }
    }
    public enum DateUnit: String, CaseIterable, Sendable {
        case days = "d", weeks = "w", months = "m", years = "y"
        public var title: String {
            switch self {
            case .days: "days"
            case .weeks: "weeks"
            case .months: "months"
            case .years: "years"
            }
        }
    }

    /// One filter from the editor's controls, as search text (nil when incomplete).
    public struct Draft: Equatable, Sendable {
        public var field: Field = .kind
        public var text = ""
        public var kind = "images"
        public var sizeComparison: SizeComparison = .larger
        public var number = 1
        public var sizeUnit: SizeUnit = .MB
        public var dateComparison: DateComparison = .withinLast
        public var dateUnit: DateUnit = .days
        public var year = Calendar.current.component(.year, from: Date())

        public init() {}

        public var token: String? {
            let t = text.trimmingCharacters(in: .whitespaces)
            switch field {
            case .kind: return "kind:\(kind)"
            case .name: return t.isEmpty ? nil : quoted(t)
            case .ext:
                let e = t.hasPrefix(".") ? String(t.dropFirst()) : t
                return e.isEmpty || e.contains(" ") ? nil : "ext:\(e.lowercased())"
            case .size: return number > 0 ? "size:\(sizeComparison == .larger ? ">" : "<")\(number)\(sizeUnit.rawValue)" : nil
            case .modified, .created, .added, .opened:
                let value: String
                switch dateComparison {
                case .withinLast: value = number > 0 ? "<\(number)\(dateUnit.rawValue)" : ""
                case .olderThan: value = number > 0 ? ">\(number)\(dateUnit.rawValue)" : ""
                case .inYear: value = (1900...9999).contains(year) ? String(year) : ""
                case .today: value = "today"
                case .yesterday: value = "yesterday"
                }
                return value.isEmpty ? nil : "\(field.rawValue):\(value)"
            case .tag: return t.isEmpty ? nil : "tag:\(quoted(t))"
            case .content: return t.isEmpty ? nil : "content:\(quoted(t))"
            case .hidden: return "hidden:yes"
            }
        }

        private func quoted(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }
    }

    /// The filters in `text`, in order, each with its words.
    public static func items(in text: String, kinds: KindCatalog = .shared) -> [(token: String, description: String)] {
        QueryParser.tokenize(text).map { ($0, describe($0, kinds: kinds)) }
    }

    public static func removing(at index: Int, from text: String) -> String {
        var tokens = QueryParser.tokenize(text)
        guard tokens.indices.contains(index) else { return text }
        tokens.remove(at: index)
        if tokens.first == "OR" { tokens.removeFirst() }
        if tokens.last == "OR" { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    public static func adding(_ token: String, to text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? token : t + " " + token
    }

    /// "size:>5MB" → "Size is larger than 5 MB".
    public static func describe(_ raw: String, kinds: KindCatalog = .shared) -> String {
        if raw == "OR" { return "or" }
        if raw.hasPrefix("-") && raw.count > 1 { return "Not: " + describe(String(raw.dropFirst()), kinds: kinds) }
        if raw.hasPrefix("/") && raw.hasSuffix("/") && raw.count > 2 { return "Name matches \(raw)" }
        guard let colon = raw.firstIndex(of: ":"), !raw.hasPrefix("\"") else { return "Name contains “\(unquote(raw))”" }
        let key = raw[..<colon].lowercased()
        let value = unquote(String(raw[raw.index(after: colon)...]))
        let list = value.split(separator: ",").map(String.init)
        func or(_ items: [String]) -> String {
            items.count <= 1 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " or " + items.last!
        }
        switch key {
        case "kind":
            return "Kind is " + or(list.map { kinds.category(QueryParser.kindAlias($0.lowercased()))?.name ?? $0 })
        case "ext", "extension": return "Extension is " + or(list.map { "." + ($0.hasPrefix(".") ? String($0.dropFirst()) : $0) })
        case "type", "uti": return "Type is \(value)"
        case "size": return "Size is " + sizeWords(value)
        case "modified", "date": return "Modified " + dateWords(value)
        case "created": return "Created " + dateWords(value)
        case "added": return "Added " + dateWords(value)
        case "opened", "lastopened": return "Last opened " + dateWords(value)
        case "tag": return "Tagged “\(value)”"
        case "content", "contents", "text": return "Contents contain “\(value)”"
        case "hidden": return ["yes", "true", "1", "y"].contains(value.lowercased()) ? "Including hidden files" : "Not including hidden files"
        default: return "Name contains “\(unquote(raw))”"
        }
    }

    private static func unquote(_ s: String) -> String {
        var s = s
        if s.hasPrefix("\"") { s.removeFirst() }
        if s.hasSuffix("\"") { s.removeLast() }
        return s
    }

    private static func amount(_ s: String) -> String {
        let digits = s.prefix { $0.isNumber || $0 == "." }
        let unit = s.dropFirst(digits.count).uppercased()
        return unit.isEmpty ? "\(digits) bytes" : "\(digits) \(unit)"
    }

    static func sizeWords(_ v: String) -> String {
        if let r = v.range(of: "..") { return "between \(amount(String(v[..<r.lowerBound]))) and \(amount(String(v[r.upperBound...])))" }
        if v.hasPrefix(">") { return "larger than " + amount(String(v.dropFirst())) }
        if v.hasPrefix("<") { return "smaller than " + amount(String(v.dropFirst())) }
        return "at least " + amount(v)
    }

    static func dateWords(_ v: String) -> String {
        let l = v.lowercased()
        if l == "today" || l == "yesterday" { return l }
        if l.hasPrefix("<") || l.hasPrefix(">"), let unit = l.last, let n = Int(l.dropFirst().dropLast()) {
            let names: [Character: String] = ["h": "hour", "d": "day", "w": "week", "m": "month", "y": "year"]
            let word = (names[unit] ?? String(unit)) + (n == 1 ? "" : "s")
            return l.hasPrefix("<") ? "within the last \(n == 1 ? "" : "\(n) ")\(word)" : "more than \(n) \(word) ago"
        }
        let parts = l.split(separator: "-").compactMap { Int($0) }
        let f = DateFormatter()
        switch parts.count {
        case 1: return "in \(parts[0])"
        case 2:
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])).map { "in " + f.string(from: $0) } ?? v
        case 3:
            f.dateStyle = .long
            return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])).map { "on " + f.string(from: $0) } ?? v
        default: return v
        }
    }
}
