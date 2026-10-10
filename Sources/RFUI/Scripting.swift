import AppKit

// AppleScript support (DESIGN.md §5.12). Resources/Foray.sdef is the dictionary; the commands and
// the application's properties below do the work through `Automation`.
//
//     tell application "Foray"
//         set current folder to POSIX file "/Users/me/Projects"
//         set found to find "report kind:pdf" in (path to documents folder)
//         reveal found
//     end tell

/// Cocoa scripting hands over files as URLs: one, or a list of them.
private func fileURLs(_ value: Any?) -> [URL] {
    switch value {
    case let url as URL: [url]
    case let list as [Any]: list.flatMap(fileURLs)
    case let path as String: [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
    default: []
    }
}

extension NSApplication {
    @objc var scriptCurrentFolder: URL? {
        get { Automation.currentFolder }
        set { if let newValue { Automation.go(to: newValue) } }
    }

    @objc var scriptSelection: [URL] {
        get { Automation.selection }
        set { Automation.select(newValue) }
    }

    @objc var scriptDualPane: Bool {
        get { Automation.isDualPane }
        set { Automation.setDualPane(newValue) }
    }
}

/// `reveal {file, …}`
@objc(ForayRevealCommand)
final class RevealScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let urls = fileURLs(directParameter)
        MainActor.assumeIsolated { Automation.reveal(urls) }
        return nil
    }
}

/// `search "text" [in folder] [contents true]`
@objc(ForaySearchCommand)
final class SearchScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String else { return nil }
        let folder = fileURLs(evaluatedArguments?["folder"]).first
        let contents = evaluatedArguments?["contents"] as? Bool ?? false
        MainActor.assumeIsolated { Automation.showSearch(text, in: folder, contents: contents) }
        return nil
    }
}

/// `find "text" [in folder] [contents true] [limit n]` → list of files. The search runs in the
/// background; the script waits for it without blocking the app.
@objc(ForayFindCommand)
final class FindScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String else { return [URL]() }
        let folder = fileURLs(evaluatedArguments?["folder"]).first
        let contents = evaluatedArguments?["contents"] as? Bool ?? false
        let limit = (evaluatedArguments?["limit"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        suspendExecution()
        nonisolated(unsafe) let command = self
        Task { @MainActor in
            let found = await Automation.find(text, in: folder, contents: contents, limit: limit)
            command.resumeExecution(withResult: found)
        }
        return nil
    }
}

/// `trash {file, …}`
@objc(ForayTrashCommand)
final class TrashScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let urls = fileURLs(directParameter)
        guard !urls.isEmpty else { return nil }
        suspendExecution()
        nonisolated(unsafe) let command = self
        Task { @MainActor in
            let problems = await Automation.trash(urls)
            if let first = problems.first {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = problems.count == 1 ? first : "\(first) (and \(problems.count - 1) more)"
            }
            command.resumeExecution(withResult: nil)
        }
        return nil
    }
}
