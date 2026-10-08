// §3.2: validate built-in kind categories against real system UTTypes.
// Prints each sample extension's resolved type, its conformance tree, and which categories match.
// Flags samples that match zero categories or an unexpected one.
import Foundation
import UniformTypeIdentifiers

struct Category {
    let name: String
    let conformsTo: [UTType]
    let extensions: Set<String>
    let excluding: [UTType]

    func matches(_ t: UTType, ext: String) -> Bool {
        if excluding.contains(where: { t.conforms(to: $0) }) { return false }
        return conformsTo.contains(where: { t.conforms(to: $0) }) || extensions.contains(ext)
    }
}

func T(_ id: String) -> UTType {
    guard let t = UTType(id) else { fatalError("unknown UTType \(id)") }
    return t
}

let code: [UTType] = [.sourceCode, .script, .json, .yaml, .xml, .propertyList]
let categories: [Category] = [
    Category(name: "Folders", conformsTo: [.folder], extensions: [], excluding: [.package]),
    Category(name: "Documents",
             conformsTo: [.pdf, .rtf, .rtfd, .plainText, T("net.daringfireball.markdown"), .spreadsheet, .presentation,
                          T("org.openxmlformats.wordprocessingml.document"), T("com.microsoft.word.doc"),
                          T("com.apple.iwork.pages.sffpages"), .epub, .html],
             extensions: ["pages", "numbers", "key", "odt", "ods", "odp"],
             excluding: code),
    Category(name: "Images", conformsTo: [.image], extensions: [], excluding: []),
    // mkv/webm/flv are dynamic (unknown) types unless a player app declares them.
    Category(name: "Video", conformsTo: [.movie], extensions: ["mkv", "webm", "flv"], excluding: []),
    Category(name: "Audio", conformsTo: [.audio], extensions: [], excluding: []),
    // Not .script/.executable: .js conforms to public.executable. Scripts count as programs only
    // when the executable bit is set (a stat predicate, not testable by extension here).
    Category(name: "Programs", conformsTo: [.application, .unixExecutable], extensions: [], excluding: []),
    Category(name: "Archives", conformsTo: [.archive, .diskImage], extensions: ["7z", "rar", "xz", "zst"], excluding: []),
    Category(name: "Code", conformsTo: code,
             extensions: ["rs", "go", "kt", "ts", "tsx", "jsx", "toml", "ini", "cfg", "gradle", "cmake", "dockerfile", "lua", "zig"],
             excluding: [.image]),   // SVG conforms to public.xml
    Category(name: "PDFs", conformsTo: [.pdf], extensions: [], excluding: []),
    Category(name: "Fonts", conformsTo: [.font], extensions: ["woff", "woff2"], excluding: []),
]

// extension -> expected categories (excluding PDFs/Fonts overlaps handled explicitly)
let samples: [(String, Set<String>)] = [
    ("pdf", ["Documents", "PDFs"]), ("txt", ["Documents"]), ("md", ["Documents"]), ("rtf", ["Documents"]),
    ("docx", ["Documents"]), ("doc", ["Documents"]), ("xlsx", ["Documents"]), ("pptx", ["Documents"]),
    ("pages", ["Documents"]), ("numbers", ["Documents"]), ("key", ["Documents"]), ("epub", ["Documents"]),
    ("csv", ["Documents"]), ("html", ["Documents"]),
    ("jpg", ["Images"]), ("heic", ["Images"]), ("png", ["Images"]), ("svg", ["Images"]), ("cr2", ["Images"]),
    ("dng", ["Images"]), ("webp", ["Images"]), ("psd", ["Images"]),
    ("mov", ["Video"]), ("mp4", ["Video"]), ("mkv", ["Video"]), ("avi", ["Video"]),
    ("mp3", ["Audio"]), ("m4a", ["Audio"]), ("flac", ["Audio"]), ("wav", ["Audio"]),
    ("app", ["Programs"]), ("sh", ["Code"]), ("command", ["Code"]), ("py", ["Code"]),
    ("zip", ["Archives"]), ("gz", ["Archives"]), ("tar", ["Archives"]), ("dmg", ["Archives"]), ("7z", ["Archives"]),
    ("rar", ["Archives"]), ("tgz", ["Archives"]), ("xz", ["Archives"]),
    ("swift", ["Code"]), ("c", ["Code"]), ("m", ["Code"]), ("js", ["Code"]), ("ts", ["Code", "Video"]), ("json", ["Code"]),
    ("yaml", ["Code"]), ("xml", ["Code"]), ("plist", ["Code"]), ("rs", ["Code"]), ("go", ["Code"]), ("toml", ["Code"]),
    ("ttf", ["Fonts"]), ("otf", ["Fonts"]), ("woff2", ["Fonts"]),
]

var problems = 0
for (ext, expected) in samples {
    let t = ext == "app" ? UTType.applicationBundle : (UTType(filenameExtension: ext) ?? .data)
    let got = Set(categories.filter { $0.matches(t, ext: ext) }.map(\.name))
    let ok = got == expected
    if !ok { problems += 1 }
    let dyn = t.isDynamic ? " (DYNAMIC)" : ""
    print("\(ok ? "  " : "!!") .\(ext.padding(toLength: 7, withPad: " ", startingAt: 0)) \(t.identifier)\(dyn)")
    if !ok {
        print("      expected \(expected.sorted()) got \(got.sorted())")
        print("      supertypes: \(t.supertypes.map(\.identifier).sorted().joined(separator: ", "))")
    }
}
// Executable without extension (what the crawl backend sees for e.g. /bin/ls).
print("\nno-extension executable resolves via file URL to:",
      (try? URL(fileURLWithPath: "/bin/ls").resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "nil")
print("\n\(problems) mismatches")
