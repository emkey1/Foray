import Foundation
import Testing

@testable import ForayCLI
@testable import RFFileSystem

/// The `foray` tool, run in-process: nothing is launched and the Trash is a private folder.
@Suite final class CLITests {
    let base: URL
    let work: URL, trashDir: URL
    let opened = Opened()

    final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var urls: [URL] { lock.withLock { stored } }
        func add(_ urls: [URL]) { lock.withLock { stored += urls } }
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    init() throws {
        // Resolved, so paths compare equal to what the tool prints (/var → /private/var).
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        base = tmp.appendingPathComponent("rf-cli-\(UUID().uuidString)", isDirectory: true)
        work = base.appendingPathComponent("work", isDirectory: true)
        trashDir = base.appendingPathComponent("Trash", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: work.appendingPathComponent("Reports/2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        for (path, text) in [("notes.txt", "plain notes"), ("Reports/report-q1.pdf", "x"), ("Reports/2026/report-q2.pdf", "x"),
                             ("Reports/summary.txt", "the quarterly figures")] {
            fm.createFile(atPath: work.appendingPathComponent(path).path, contents: Data(text.utf8))
        }
    }

    private func cli(openError: String? = nil, scheme: String = "foray") -> CLI {
        let trashDir = trashDir, opened = opened
        return CLI(.init(currentDirectory: work, openInApp: { urls in
            opened.add(urls)
            return openError
        }, trash: { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }, scheme: scheme, version: "1.2.3"))
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: work.appendingPathComponent(path).path) }

    @Test func helpAndVersion() async {
        let help = await cli().run(["--help"])
        #expect(help.status == 0 && help.out.contains("usage: foray") && help.err.isEmpty)
        #expect(await cli().run(["--version"]) == CLI.Output(out: "foray 1.2.3\n"))
    }

    @Test func noArgumentsOpensTheCurrentDirectory() async {
        let out = await cli().run([])
        #expect(out == CLI.Output())
        #expect(opened.urls.map(\.path) == [work.path])
    }

    @Test func opensRelativeAndAbsolutePathsAndReportsMissingOnes() async {
        let out = await cli().run(["Reports", work.appendingPathComponent("notes.txt").path, "nope"])
        #expect(out.status == 1)
        #expect(out.err == "foray: nope: No such file or directory\n")
        #expect(opened.urls.map(\.path) == [work.appendingPathComponent("Reports").path, work.appendingPathComponent("notes.txt").path])
        // "open" is the same thing spelled out.
        #expect(await cli().run(["open", "Reports"]).status == 0)
    }

    @Test func nothingIsOpenedWhenEveryPathIsMissing() async {
        let out = await cli().run(["nope"])
        #expect(out.status == 1 && opened.urls.isEmpty)
    }

    @Test func unknownOptionsAreUsageErrors() async {
        let out = await cli().run(["--frobnicate"])
        #expect(out.status == 64 && out.err.contains("unknown option --frobnicate") && opened.urls.isEmpty)
    }

    @Test func revealSendsARevealLinkWithTheAppsScheme() async throws {
        let out = await cli(scheme: "foray-dev").run(["reveal", "Reports"])
        #expect(out == CLI.Output())
        let link = try #require(opened.urls.first)
        #expect(link.scheme == "foray-dev" && link.host == "reveal")
        let path = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        #expect(path == work.appendingPathComponent("Reports").path)
        #expect(await cli().run(["reveal"]).status == 64)
    }

    @Test func aFailureToReachTheAppIsReported() async {
        let out = await cli(openError: "can't find the Foray app").run(["Reports"])
        #expect(out.status == 1 && out.err == "foray: can't find the Foray app\n")
    }

    @Test func searchPrintsSortedPathsUnderTheCurrentDirectory() async {
        let out = await cli().run(["search", "report"])
        #expect(out.status == 0)
        // The "Reports" folder matches too.
        #expect(out.out == ["Reports", "Reports/2026/report-q2.pdf", "Reports/report-q1.pdf"]
            .map { work.appendingPathComponent($0).path + "\n" }.joined())
    }

    @Test func searchOptions() async {
        // --in narrows it; -0 separates with NULs; -n stops early.
        let narrowed = await cli().run(["search", "--in", "Reports/2026", "-0", "report"])
        #expect(narrowed.out == work.appendingPathComponent("Reports/2026/report-q2.pdf").path + "\0")
        let limited = await cli().run(["search", "-n", "1", "report"])
        #expect(limited.out.split(separator: "\n").count == 1)
        // Foray's search syntax works: several words are one query.
        let typed = await cli().run(["search", "report", "kind:pdf"])
        #expect(typed.out.split(separator: "\n").count == 2)
        // Nothing found: status 1 and no output, like grep.
        #expect(await cli().run(["search", "zzz-not-there"]) == CLI.Output(status: 1))
    }

    @Test func searchUsageErrors() async {
        #expect(await cli().run(["search"]).status == 64)
        #expect(await cli().run(["search", "-n", "many", "x"]).status == 64)
        #expect(await cli().run(["search", "--in"]).status == 64)
        let notAFolder = await cli().run(["search", "--in", "notes.txt", "x"])
        #expect(notAFolder.status == 1 && notAFolder.err.contains("Not a folder"))
    }

    @Test func searchOpenShowsItInTheApp() async throws {
        let out = await cli().run(["search", "--open", "--mac", "report", "kind:pdf"])
        #expect(out == CLI.Output())
        let link = try #require(opened.urls.first)
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(link.host == "search")
        #expect(items.first { $0.name == "q" }?.value == "report kind:pdf")
        #expect(!items.contains { $0.name == "in" })          // --mac: no folder
        _ = await cli().run(["search", "-o", "x"])
        let scoped = URLComponents(url: opened.urls[1], resolvingAgainstBaseURL: false)?.queryItems
        #expect(scoped?.first { $0.name == "in" }?.value == work.path)
    }

    @Test func trashMovesItemsAndKeepsGoingPastMissingOnes() async {
        let out = await cli().run(["trash", "notes.txt", "nope", "Reports/2026"])
        #expect(out.status == 1 && out.err == "foray: nope: No such file or directory\n")
        #expect(!exists("notes.txt") && !exists("Reports/2026") && exists("Reports/report-q1.pdf"))
        #expect(Set(try! FileManager.default.contentsOfDirectory(atPath: trashDir.path)) == ["notes.txt", "2026"])
        #expect(await cli().run(["trash"]).status == 64)
    }

    @Test func tagAddsRemovesAndLists() async {
        #expect(await cli().run(["tag", "-a", "Work", "-a", "Urgent", "notes.txt"]) == CLI.Output())
        #expect(await cli().run(["tag", "notes.txt"]).out == "Work, Urgent\n")
        // Adding a tag again (any case) doesn't duplicate it; removing is case-insensitive too.
        #expect(await cli().run(["tag", "-a", "work", "-r", "URGENT", "notes.txt"]) == CLI.Output())
        #expect(Tags.names(at: work.appendingPathComponent("notes.txt")) == ["Work"])
        // Several paths: each line names its file.
        let listed = await cli().run(["tag", "notes.txt", "Reports"])
        #expect(listed.out == "\(work.path)/notes.txt: Work\n\(work.path)/Reports: \n")
        #expect(await cli().run(["tag", "-a"]).status == 64)
        #expect(await cli().run(["tag", "-a", "x"]).status == 64)
    }
}
