import Foundation

/// Finder-compatible names for new items (DESIGN.md §5.7).
public enum FileNaming {
    /// Splits "photo.jpg" into ("photo", "jpg"). Names whose "extension" contains spaces or is
    /// unusually long ("v1.2 notes", "Mr. Smith") are treated as having none, like Finder.
    public static func split(_ name: String) -> (base: String, ext: String?) {
        let ns = name as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty, ext.count <= 12, !ext.contains(" "), ns.deletingPathExtension.count > 0 else {
            return (name, nil)
        }
        return (ns.deletingPathExtension, ext)
    }

    private static func join(_ base: String, _ ext: String?) -> String {
        ext.map { "\(base).\($0)" } ?? base
    }

    /// Keep Both: "report.pdf" → "report 2.pdf" → "report 3.pdf"; "report 2.pdf" → "report 3.pdf".
    public static func keepBothName(for name: String, isTaken: (String) -> Bool) -> String {
        let (base, ext) = split(name)
        var stem = base
        var n = 2
        // An existing trailing number continues counting from there.
        if let range = base.range(of: #" (\d+)$"#, options: .regularExpression),
           let current = Int(base[range].dropFirst()) {
            stem = String(base[..<range.lowerBound])
            n = current + 1
        }
        while true {
            let candidate = join("\(stem) \(n)", ext)
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// The name itself if free, else the Keep Both name ("Archive.zip" → "Archive 2.zip").
    public static func keepBothFreeName(_ name: String, isTaken: (String) -> Bool) -> String {
        isTaken(name) ? keepBothName(for: name, isTaken: isTaken) : name
    }

    /// Duplicate: "report.pdf" → "report copy.pdf" → "report copy 2.pdf".
    public static func duplicateName(for name: String, isTaken: (String) -> Bool) -> String {
        let (base, ext) = split(name)
        let first = join("\(base) copy", ext)
        if !isTaken(first) { return first }
        var n = 2
        while true {
            let candidate = join("\(base) copy \(n)", ext)
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// New Folder: "untitled folder", "untitled folder 2", …
    public static func newFolderName(base: String = "untitled folder", isTaken: (String) -> Bool) -> String {
        if !isTaken(base) { return base }
        var n = 2
        while isTaken("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Why a name can't be used, or nil if it's fine. (":" is allowed: Finder shows it as "/".)
    public static func problem(with name: String) -> String? {
        if name.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty { return "A name can't be empty." }
        if name == "." || name == ".." { return "“\(name)” is reserved by the system." }
        if name.contains("/") { return "Names can't contain “/”." }
        if name.utf8.count > 255 { return "That name is too long." }
        return nil
    }
}
