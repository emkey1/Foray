import Foundation
import RFModel
import UniformTypeIdentifiers

/// Translates a query into Spotlight's metadata query language (DESIGN.md §3.2, §5.6). Returns nil
/// when Spotlight can't express it (regexes): the planner then crawls instead. Everything Spotlight
/// returns is re-checked with `QueryMatcher`, so translations may be broader than the query.
enum SpotlightQuery {
    static func string(for query: SearchQuery, kinds: KindCatalog = .shared) -> String? {
        let root = query.parsed
        if root.contains(where: { if case .regex = $0 { true } else { false } }) { return nil }
        let s = node(root, query.match, kinds)
        return s.isEmpty ? "kMDItemFSName == \"*\"" : s
    }

    private static func node(_ n: QueryNode, _ match: MatchMode, _ kinds: KindCatalog) -> String {
        switch n {
        case .all(let nodes): return join(nodes.map { node($0, match, kinds) }, "&&")
        case .any(let nodes): return join(nodes.map { node($0, match, kinds) }, "||")
        case .not(let inner):
            let s = node(inner, match, kinds)
            return s.isEmpty ? "" : "!(\(s))"
        case .term(let t): return term(t, match, kinds)
        }
    }

    private static func join(_ parts: [String], _ op: String) -> String {
        let nonEmpty = parts.filter { !$0.isEmpty }
        if nonEmpty.isEmpty { return "" }
        if nonEmpty.count == 1 { return nonEmpty[0] }
        return "(" + nonEmpty.joined(separator: " \(op) ") + ")"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func iso(_ d: Date) -> String {
        "$time.iso(\(ISO8601DateFormatter().string(from: d)))"
    }

    private static func term(_ t: SearchTerm, _ match: MatchMode, _ kinds: KindCatalog) -> String {
        switch t {
        case .name(let s):
            let isGlob = s.contains("*") || s.contains("?")
            let name = "kMDItemFSName == \"\(isGlob ? escape(s) : "*" + escape(s) + "*")\"cd"
            guard match == .namesAndContents, !isGlob else { return name }
            return "(\(name) || \(contentWords(s)))"
        case .regex:
            return ""
        case .kind(let ids):
            return join(ids.compactMap { kinds.category($0) }.map(category), "||")
        case .ext(let exts):
            return join(exts.sorted().map { "kMDItemFSName == \"*.\(escape($0))\"c" }, "||")
        case .type(let id):
            return "kMDItemContentTypeTree == \"\(escape(id))\""
        case .size(let lo, let hi):
            return join([lo.map { "kMDItemFSSize >= \($0)" }, hi.map { "kMDItemFSSize <= \($0)" }].compactMap { $0 }, "&&")
        case .date(let field, let from, let to):
            let attr = switch field {
            case .modified: "kMDItemFSContentChangeDate"
            case .created: "kMDItemFSCreationDate"
            case .added: "kMDItemDateAdded"
            case .opened: "kMDItemLastUsedDate"
            }
            return join([from.map { "\(attr) >= \(iso($0))" }, to.map { "\(attr) < \(iso($0))" }].compactMap { $0 }, "&&")
        case .tag(let name):
            return "kMDItemUserTags == \"\(escape(name))\"cd"
        case .content(let text):
            return contentWords(text)
        case .hidden:
            return ""
        }
    }

    /// Word-prefix matches on extracted text, like Finder's "Contents contains".
    private static func contentWords(_ text: String) -> String {
        join(text.split(whereSeparator: \.isWhitespace).map { "kMDItemTextContent == \"\(escape(String($0)))*\"cdw" }, "&&")
    }

    /// A kind category as conformance (kMDItemContentTypeTree) and extension rules. The executable
    /// bit can't be expressed; crawls find those, and every hit is re-checked anyway.
    private static func category(_ c: KindCategory) -> String {
        var any = c.conformsTo.map { "kMDItemContentTypeTree == \"\($0)\"" }
        any += c.extensions.map { "kMDItemFSName == \"*.\($0)\"c" }
        let positive = join(any, "||")
        let exclusions = c.excluding.map { "kMDItemContentTypeTree != \"\($0)\"" }
        return exclusions.isEmpty ? positive : join([positive] + exclusions, "&&")
    }
}
