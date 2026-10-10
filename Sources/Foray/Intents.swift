import AppIntents
import Foundation
import RFUI
import UniformTypeIdentifiers

// Shortcuts actions (App Intents, DESIGN.md §5.12). They call the same `Automation` API as
// AppleScript, so the two behave alike. This file is compiled into the app itself (not the
// ForayKit package) so Xcode extracts the actions' metadata for Shortcuts.

/// Shortcuts passes files as `IntentFile`; Foray works on the files where they are.
private func urls(_ files: [IntentFile]) throws -> [URL] {
    let urls = files.compactMap(\.fileURL)
    guard urls.count == files.count else { throw ForayIntentError.notOnDisk }
    return urls
}

enum ForayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notOnDisk
    case noFolder
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notOnDisk: "Foray needs files or folders that are saved on disk."
        case .noFolder: "The front Foray window isn't showing a folder."
        case .failed(let message): "\(message)"
        }
    }
}

struct OpenInForayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Foray"
    static let description = IntentDescription("Opens folders in Foray. Files are shown selected in their folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Items", supportedContentTypes: [.item, .folder])
    var items: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$items) in Foray") }

    @MainActor
    func perform() async throws -> some IntentResult {
        Automation.open(try urls(items))
        return .result()
    }
}

struct RevealInForayIntent: AppIntent {
    static let title: LocalizedStringResource = "Reveal in Foray"
    static let description = IntentDescription("Shows files and folders selected in their enclosing folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Items", supportedContentTypes: [.item, .folder])
    var items: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Reveal \(\.$items) in Foray") }

    @MainActor
    func perform() async throws -> some IntentResult {
        Automation.reveal(try urls(items))
        return .result()
    }
}

struct FindFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files with Foray"
    static let description = IntentDescription(
        "Searches by name (and optionally contents) using Foray's search syntax, such as “report kind:pdf”, and returns the files found.")

    @Parameter(title: "Search", description: "What to look for, in Foray's search syntax.")
    var text: String

    @Parameter(title: "Folder", description: "The folder to search, including its subfolders. Leave empty to search the whole Mac.",
               supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Search File Contents", default: false)
    var contents: Bool

    @Parameter(title: "Limit", description: "Stop after this many items. Leave empty for no limit.", inclusiveRange: (1, 100_000))
    var limit: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$text) in \(\.$folder)") {
            \.$contents
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let scope = try folder.map { try urls([$0])[0] }
        let found = await Automation.find(text, in: scope, contents: contents, limit: limit)
        return .result(value: found.map { IntentFile(fileURL: $0) })
    }
}

struct ShowSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Foray"
    static let description = IntentDescription("Runs a search in the front Foray window and shows the results.")
    static let openAppWhenRun = true

    @Parameter(title: "Search", description: "What to look for, in Foray's search syntax.")
    var text: String

    @Parameter(title: "Folder", description: "The folder to search, including its subfolders. Leave empty to search the whole Mac.",
               supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Search File Contents", default: false)
    var contents: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$text) in \(\.$folder)") { \.$contents }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Automation.showSearch(text, in: try folder.map { try urls([$0])[0] }, contents: contents)
        return .result()
    }
}

struct GetSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Selected Files in Foray"
    static let description = IntentDescription("Returns the items selected in the front Foray window.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: Automation.selection.map { IntentFile(fileURL: $0) })
    }
}

struct GetCurrentFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Folder in Foray"
    static let description = IntentDescription("Returns the folder shown in the front Foray window.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let folder = Automation.currentFolder else { throw ForayIntentError.noFolder }
        return .result(value: IntentFile(fileURL: folder))
    }
}

struct MoveToTrashIntent: AppIntent {
    static let title: LocalizedStringResource = "Move to Trash with Foray"
    static let description = IntentDescription("Moves files and folders to the Trash. Foray's Undo and Put Back work as usual.")

    @Parameter(title: "Items", supportedContentTypes: [.item, .folder])
    var items: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Move \(\.$items) to the Trash") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let problems = await Automation.trash(try urls(items))
        if let first = problems.first { throw ForayIntentError.failed(first) }
        return .result()
    }
}
