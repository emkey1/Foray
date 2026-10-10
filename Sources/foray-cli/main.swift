import AppKit
import ForayCLI
import RFOperations

// The `foray` command-line tool. It ships inside the app at Foray.app/Contents/Helpers/foray;
// Settings › Advanced installs a link to it in /usr/local/bin (Homebrew does it automatically).

/// The app this tool belongs to: the bundle it sits in, or else an installed Foray.
func hostApp() -> URL? {
    let tool = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let me = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? tool
    var dir = me.deletingLastPathComponent()
    for _ in 0..<3 {
        if dir.pathExtension == "app" { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return ["io.github.emkey1.Foray", "io.github.emkey1.Foray.dev"].lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
}

let app = hostApp()
let info = app.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
let scheme = ((info?["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "foray"
let version = info?["CFBundleShortVersionString"] as? String ?? "dev"

let environment = CLI.Environment(
    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    openInApp: { urls in
        guard let app else { return "can't find the Foray app" }
        return await withCheckedContinuation { done in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
                done.resume(returning: error?.localizedDescription)
            }
        }
    },
    trash: Trash.system, scheme: scheme, version: version)

let output = await CLI(environment).run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(output.out.utf8))
FileHandle.standardError.write(Data(output.err.utf8))
exit(output.status)
