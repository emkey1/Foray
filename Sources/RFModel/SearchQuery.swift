import Foundation
import UniformTypeIdentifiers

public enum MatchMode: String, Codable, Sendable {
    /// File names only (the default: content matching floods results, DESIGN.md §3.1).
    case names
    case namesAndContents
}

public enum SearchScope: Hashable, Codable, Sendable {
    case folder(URL, recursive: Bool)
    case thisMac

    public var folderURL: URL? {
        if case .folder(let url, _) = self { return url }
        return nil
    }
}

/// A search (DESIGN.md §3.1). The field text is the single source of truth for terms: scope-bar
/// chips edit `kind:` tokens in the text, so the field always shows the whole query.
public struct SearchQuery: Hashable, Codable, Sendable {
    public var text: String
    public var scope: SearchScope
    public var match: MatchMode
    /// The folder the search started from: the scope bar's folder button, and where Escape returns.
    public var origin: URL?
    /// A smart folder made by Finder: its Spotlight query, run as is. `text` is then the smart
    /// folder's name; typing in the search field replaces it with an ordinary search.
    public var rawSpotlight: String?

    public init(text: String, scope: SearchScope, match: MatchMode = .names, origin: URL? = nil, rawSpotlight: String? = nil) {
        self.text = text
        self.scope = scope
        self.match = match
        self.origin = origin ?? scope.folderURL
        self.rawSpotlight = rawSpotlight
    }

    public var parsed: QueryNode { rawSpotlight == nil ? QueryParser.parse(text) : .all([]) }
    public var isEmpty: Bool { rawSpotlight == nil && text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `hidden:yes` anywhere in the query.
    public var includeHidden: Bool { parsed.contains { if case .hidden(true) = $0 { true } else { false } } }

    /// Top-level positive `kind:` categories (what the scope-bar chips show).
    public var kinds: Set<KindCategory.ID> {
        var ids = Set<KindCategory.ID>()
        for node in parsed.topLevelTerms { if case .term(.kind(let k)) = node { ids.formUnion(k) } }
        return ids
    }

    /// Rewrites the text so its top-level `kind:` tokens equal `ids` (used by the chips).
    public func settingKinds(_ ids: Set<KindCategory.ID>) -> SearchQuery {
        var tokens = QueryParser.tokenize(text).filter { !$0.lowercased().hasPrefix("kind:") }
        if !ids.isEmpty { tokens.append("kind:" + ids.sorted().joined(separator: ",")) }
        var q = self
        q.text = tokens.joined(separator: " ")
        return q
    }
}

// MARK: - Query tree

public enum Comparison: String, Codable, Sendable { case less, greater, equal }

public enum DateField: String, Codable, Sendable { case modified, created, added, opened }

public enum SearchTerm: Hashable, Codable, Sendable {
    /// Substring, or a glob when it contains `*` or `?`. Case- and diacritic-insensitive.
    case name(String)
    case regex(String)
    case kind(Set<KindCategory.ID>)
    case ext(Set<String>)
    case type(String)
    case size(min: Int64?, max: Int64?)
    case date(DateField, from: Date?, to: Date?)
    case tag(String)
    case content(String)
    case hidden(Bool)
}

public indirect enum QueryNode: Hashable, Codable, Sendable {
    case all([QueryNode])
    case any([QueryNode])
    case not(QueryNode)
    case term(SearchTerm)

    public static let matchEverything = QueryNode.all([])

    var topLevelTerms: [QueryNode] {
        if case .all(let nodes) = self { return nodes }
        return [self]
    }

    public func contains(where predicate: (SearchTerm) -> Bool) -> Bool {
        switch self {
        case .all(let n), .any(let n): n.contains { $0.contains(where: predicate) }
        case .not(let n): n.contains(where: predicate)
        case .term(let t): predicate(t)
        }
    }

    /// Positive name terms every match must contain (used to pre-filter crawls by name).
    public var requiredNameFragments: [String] {
        topLevelTerms.compactMap { if case .term(.name(let s)) = $0 { s } else { nil } }
    }

    public var hasContentTerms: Bool { contains { if case .content = $0 { true } else { false } } }
    public var hasTagTerms: Bool { contains { if case .tag = $0 { true } else { false } } }
}

// MARK: - Parser

public enum QueryParser {
    /// Splits on whitespace, keeping "quoted phrases" (and key:"quoted values") together.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        // Commas between filters ("size:>1MB, modified:<7d") are separators, not part of values.
        return tokens.compactMap { token in
            guard !token.hasSuffix("\"") else { return token }
            let trimmed = String(token.reversed().drop(while: { $0 == "," }).reversed())
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static let knownKeys: Set<String> = [
        "kind", "ext", "extension", "type", "uti", "size", "modified", "date", "created", "added", "opened",
        "lastopened", "tag", "content", "contents", "text", "hidden",
    ]

    /// Filters that look like `key:value` with a known key but a value we can't read, e.g.
    /// "size:>1XB" or "kind:nonsense". They're left out of the query (rather than becoming a name
    /// search that silently matches nothing) and shown to the user.
    public static func problems(in text: String, kinds: KindCatalog = .shared) -> [String] {
        tokenize(text).filter { raw in
            let token = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
            guard let colon = token.firstIndex(of: ":"), !token.hasPrefix("\"") else { return false }
            let key = token[..<colon].lowercased()
            guard knownKeys.contains(key) else { return false }
            let value = unquote(token[token.index(after: colon)...])
            guard let term = keyed(key, value, now: Date(), calendar: .current) else { return true }
            if case .kind(let ids) = term { return ids.contains { kinds.category($0) == nil } }
            return false
        }
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> QueryNode {
        var pendingOr = false
        var conjunction: [QueryNode] = []
        for raw in tokenize(text) {
            if raw == "OR" {
                pendingOr = true
                continue
            }
            guard let node = parseToken(raw, now: now, calendar: calendar) else { continue }
            if pendingOr, let last = conjunction.popLast() {
                // `a OR b`: binds tighter than the implicit AND around it.
                if case .any(let alts) = last {
                    conjunction.append(.any(alts + [node]))
                } else {
                    conjunction.append(.any([last, node]))
                }
            } else {
                conjunction.append(node)
            }
            pendingOr = false
        }
        return .all(conjunction)
    }

    static func parseToken(_ raw: String, now: Date, calendar: Calendar) -> QueryNode? {
        var token = raw
        var negated = false
        if token.hasPrefix("-") && token.count > 1 {
            negated = true
            token.removeFirst()
        }
        let node = parsePositive(token, now: now, calendar: calendar)
        guard let node else { return nil }
        return negated ? .not(node) : node
    }

    private static func unquote(_ s: Substring) -> String {
        var s = String(s)
        if s.hasPrefix("\"") { s.removeFirst() }
        if s.hasSuffix("\"") { s.removeLast() }
        return s
    }

    private static func parsePositive(_ token: String, now: Date, calendar: Calendar) -> QueryNode? {
        if token.hasPrefix("/") && token.hasSuffix("/") && token.count > 2 {
            return .term(.regex(String(token.dropFirst().dropLast())))
        }
        if let colon = token.firstIndex(of: ":"), !token.hasPrefix("\"") {
            let key = token[..<colon].lowercased()
            let value = unquote(token[token.index(after: colon)...])
            if let term = keyed(key, value, now: now, calendar: calendar) { return .term(term) }
            if knownKeys.contains(key) { return nil }  // reported by `problems(in:)`
        }
        let text = unquote(Substring(token))
        return text.isEmpty ? nil : .term(.name(text))
    }

    private static func keyed(_ key: String, _ value: String, now: Date, calendar: Calendar) -> SearchTerm? {
        let list = Set(value.lowercased().split(separator: ",").map(String.init).filter { !$0.isEmpty })
        switch key {
        case "kind": return list.isEmpty ? nil : .kind(Set(list.map(kindAlias)))
        case "ext", "extension": return list.isEmpty ? nil : .ext(Set(list.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }))
        case "type", "uti": return value.isEmpty ? nil : .type(value)
        case "size": return parseSize(value)
        case "modified", "date": return parseDate(.modified, value, now: now, calendar: calendar)
        case "created": return parseDate(.created, value, now: now, calendar: calendar)
        case "added": return parseDate(.added, value, now: now, calendar: calendar)
        case "opened", "lastopened": return parseDate(.opened, value, now: now, calendar: calendar)
        case "tag": return value.isEmpty ? nil : .tag(value)
        case "content", "contents", "text": return value.isEmpty ? nil : .content(value)
        case "hidden": return .hidden(["yes", "true", "1", "y"].contains(value.lowercased()))
        default: return nil  // unknown key: treat the whole token as a name
        }
    }

    /// Accepts singular/plural and a few Finder-style synonyms for built-in categories.
    static func kindAlias(_ s: String) -> String {
        switch s {
        case "image", "picture", "pictures", "photo", "photos": "images"
        case "document", "doc", "docs": "documents"
        case "movie", "movies", "videos": "video"
        case "music", "sound": "audio"
        case "app", "apps", "application", "applications", "program": "programs"
        case "archive", "zip": "archives"
        case "source", "sourcecode": "code"
        case "pdf": "pdfs"
        case "font": "fonts"
        case "folder", "directory", "directories": "folders"
        default: s
        }
    }

    // size:>100MB  size:<1KB  size:1MB..5MB  size:10MB (at least)
    static func parseSize(_ value: String) -> SearchTerm? {
        if let range = value.range(of: "..") {
            guard let lo = bytes(String(value[..<range.lowerBound])), let hi = bytes(String(value[range.upperBound...])) else { return nil }
            return .size(min: lo, max: hi)
        }
        if value.hasPrefix(">") { return bytes(String(value.dropFirst())).map { .size(min: $0 + 1, max: nil) } }
        if value.hasPrefix("<") { return bytes(String(value.dropFirst())).map { .size(min: nil, max: $0 - 1) } }
        return bytes(value).map { .size(min: $0, max: nil) }
    }

    static func bytes(_ s: String) -> Int64? {
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("k", 1e3), ("m", 1e6), ("g", 1e9), ("b", 1)]
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
        for (suffix, scale) in units where lower.hasSuffix(suffix) {
            guard let n = Double(lower.dropLast(suffix.count)) else { return nil }
            return Int64(n * scale)
        }
        return Double(lower).map { Int64($0) }
    }

    // modified:<7d (newer than 7 days)  >30d (older)  today  yesterday  2025  2025-10  2025-10-01
    static func parseDate(_ field: DateField, _ value: String, now: Date, calendar: Calendar) -> SearchTerm? {
        let v = value.lowercased()
        if v == "today" { return .date(field, from: calendar.startOfDay(for: now), to: nil) }
        if v == "yesterday" {
            let today = calendar.startOfDay(for: now)
            return .date(field, from: calendar.date(byAdding: .day, value: -1, to: today), to: today)
        }
        if v.hasPrefix("<") || v.hasPrefix(">") {
            guard let ago = age(String(v.dropFirst()), now: now, calendar: calendar) else { return nil }
            return v.hasPrefix("<") ? .date(field, from: ago, to: nil) : .date(field, from: nil, to: ago)
        }
        let parts = v.split(separator: "-").compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == v.split(separator: "-").count else { return nil }
        let c = DateComponents(year: parts[0], month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
        guard let start = calendar.date(from: c) else { return nil }
        let span: Calendar.Component = parts.count == 1 ? .year : (parts.count == 2 ? .month : .day)
        return .date(field, from: start, to: calendar.date(byAdding: span, value: 1, to: start))
    }

    private static func age(_ s: String, now: Date, calendar: Calendar) -> Date? {
        guard let unit = s.last, let n = Int(s.dropLast()) else { return nil }
        let component: Calendar.Component
        switch unit {
        case "h": component = .hour
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        case "y": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -n, to: now)
    }
}

// MARK: - Matching

/// Evaluates a query against an item. `tags` is consulted only for tag terms; `contentMatches`
/// is what the caller knows about content terms (Spotlight hits: true; crawl: false).
public struct QueryMatcher: Sendable {
    public let root: QueryNode
    public let kinds: KindCatalog
    public let match: MatchMode
    private let regexes: [String: NSRegularExpression]

    public init(_ query: SearchQuery, kinds: KindCatalog = .shared) {
        root = query.parsed
        self.kinds = kinds
        match = query.match
        var compiled: [String: NSRegularExpression] = [:]
        _ = root.contains { term in
            if case .regex(let p) = term { compiled[p] = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
            if case .name(let n) = term, n.contains("*") || n.contains("?") { compiled["glob:" + n] = Self.glob(n) }
            return false
        }
        regexes = compiled
    }

    public func matches(_ item: FileItem, tags: [String] = [], contentMatches: Bool = false) -> Bool {
        evaluate(root, item, tags, contentMatches)
    }

    private func evaluate(_ node: QueryNode, _ item: FileItem, _ tags: [String], _ content: Bool) -> Bool {
        switch node {
        case .all(let nodes): return nodes.allSatisfy { evaluate($0, item, tags, content) }
        case .any(let nodes): return nodes.contains { evaluate($0, item, tags, content) }
        case .not(let n): return !evaluate(n, item, tags, content)
        case .term(let t): return evaluate(t, item, tags, content)
        }
    }

    private func evaluate(_ term: SearchTerm, _ item: FileItem, _ tags: [String], _ content: Bool) -> Bool {
        switch term {
        case .name(let s):
            // In Names & Contents mode a Spotlight hit may have matched on contents.
            if match == .namesAndContents && content { return true }
            if let re = regexes["glob:" + s] {
                let folded = item.name.folding(options: [.diacriticInsensitive], locale: nil)
                return re.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
            }
            return item.name.range(of: s, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (item.displayName != item.name && item.displayName.range(of: s, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        case .regex(let p):
            guard let re = regexes[p] else { return false }
            return re.firstMatch(in: item.name, range: NSRange(item.name.startIndex..., in: item.name)) != nil
        case .kind(let ids):
            return kinds.matches(item, anyOf: ids)
        case .ext(let exts):
            return exts.contains(item.pathExtension)
        case .type(let id):
            return UTType(id).map { item.contentType.conforms(to: $0) } ?? false
        case .size(let lo, let hi):
            guard !item.isNavigableFolder, let size = item.size else { return false }
            return (lo.map { size >= $0 } ?? true) && (hi.map { size <= $0 } ?? true)
        case .date(let field, let from, let to):
            let date: Date? = switch field {
            case .modified: item.modified
            case .created: item.created
            case .added: item.added
            case .opened: nil  // Spotlight-only attribute; Spotlight applies it
            }
            guard let date else { return field == .opened && content }
            return (from.map { date >= $0 } ?? true) && (to.map { date < $0 } ?? true)
        case .tag(let name):
            return tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        case .content:
            return content
        case .hidden:
            return true  // an option, not a filter
        }
    }

    /// `*` and `?` glob over the whole name, case- and diacritic-insensitive.
    public static func glob(_ pattern: String) -> NSRegularExpression? {
        var re = "^"
        for ch in pattern.folding(options: [.diacriticInsensitive], locale: nil) {
            switch ch {
            case "*": re += ".*"
            case "?": re += "."
            default: re += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return try? NSRegularExpression(pattern: re + "$", options: [.caseInsensitive])
    }
}
