import Darwin
import Foundation
import RFFileSystem
import RFModel

/// Make Alias, Compress and Expand. Each records what it created, so undo moves it to the Trash.
extension Execution {
    func makeAliases(_ items: [URL], in folder: URL?) async {
        update {
            $0.itemsTotal = items.count
            $0.phase = .running
        }
        for item in items {
            guard control.checkpoint() else { break }
            let dir = folder ?? item.deletingLastPathComponent()
            update { $0.currentName = item.lastPathComponent }
            let outcome: Result<URL, NSError> = await blocking {
                let name = Aliases.name(for: item.lastPathComponent) { FileOps.exists(dir.appendingPathComponent($0)) }
                let alias = dir.appendingPathComponent(name)
                do {
                    try Aliases.make(to: item, at: alias)
                    return .success(alias)
                } catch {
                    return .failure(error as NSError)
                }
            }
            switch outcome {
            case .success(let alias):
                result.record(.created(alias))
                result.changedFolders.insert(dir)
            case .failure(let error):
                fail(item, Self.errno(of: error), "make an alias of")
            }
            update { $0.itemsDone += 1 }
        }
    }

    func compress(_ items: [URL]) async {
        guard let first = items.first else { return }
        update {
            $0.itemsTotal = 1
            $0.phase = .running
            $0.currentName = items.count == 1 ? first.lastPathComponent : "Archive.zip"
        }
        let dir = first.deletingLastPathComponent()
        let base = items.count == 1 ? first.lastPathComponent : "Archive"
        let name = await blocking { FileNaming.keepBothFreeName("\(base).zip") { FileOps.exists(dir.appendingPathComponent($0)) } }
        let target = dir.appendingPathComponent(name)
        let temp = OperationJournal.temporaryURL(for: target)
        journal.begin(temp)
        defer { journal.end(temp) }
        let control = control
        let rc: Int32 = await blocking {
            if items.count == 1 {
                return Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, temp.path], control: control)
            }
            // ditto takes one source: stage the items (cloned, so it's cheap) and zip the stage's contents.
            let stage = OperationJournal.temporaryURL(for: dir.appendingPathComponent("Archive"))
            defer { FileOps.removeTree(stage) }
            guard mkdir(stage.path, 0o700) == 0 else { return Darwin.errno }
            for item in items {
                let rc = Tool.run("/usr/bin/ditto", [item.path, stage.appendingPathComponent(item.lastPathComponent).path], control: control)
                if rc != 0 { return rc }
            }
            return Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", stage.path, temp.path], control: control)
        }
        guard rc == 0, control.checkpoint() else {
            await blocking { FileOps.removeTree(temp) }
            if rc != ECANCELED { fail(first, rc == 0 ? ECANCELED : rc, "compress") }
            return
        }
        if let final = await placeTemporary(temp, at: target, for: first, action: "compress") {
            result.record(.created(final))
            result.changedFolders.insert(dir)
        }
        update { $0.itemsDone = 1 }
    }

    func expand(_ archives: [URL]) async {
        update {
            $0.itemsTotal = archives.count
            $0.phase = .running
        }
        for archive in archives {
            guard control.checkpoint() else { break }
            update { $0.currentName = archive.lastPathComponent }
            let dir = archive.deletingLastPathComponent()
            let temp = OperationJournal.temporaryURL(for: dir.appendingPathComponent(archive.lastPathComponent + "-expanded"))
            journal.begin(temp)
            defer { journal.end(temp) }
            let control = control
            let rc: Int32 = await blocking {
                guard mkdir(temp.path, 0o755) == 0 else { return Darwin.errno }
                return Tool.run("/usr/bin/ditto", ["-x", "-k", archive.path, temp.path], control: control)
            }
            guard rc == 0 else {
                await blocking { FileOps.removeTree(temp) }
                if rc != ECANCELED { fail(archive, rc, "expand") }
                continue
            }
            // One top-level item goes beside the archive; several stay in a folder named after it.
            let contents = await blocking {
                ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0 != "__MACOSX" }
            }
            let created: URL?
            if contents.count == 1 {
                let only = temp.appendingPathComponent(contents[0])
                created = await placeTemporary(only, at: dir.appendingPathComponent(contents[0]), for: archive, action: "expand")
                await blocking { FileOps.removeTree(temp) }
            } else {
                let folder = (archive.lastPathComponent as NSString).deletingPathExtension
                created = await placeTemporary(temp, at: dir.appendingPathComponent(folder), for: archive, action: "expand")
            }
            if let created {
                result.record(.created(created))
                result.changedFolders.insert(dir)
            }
            update { $0.itemsDone += 1 }
        }
    }

    /// Renames a finished temporary item into place, keeping both if the name is taken.
    private func placeTemporary(_ temp: URL, at target: URL, for item: URL, action: String) async -> URL? {
        let outcome: (URL, Int32) = await blocking {
            let dir = target.deletingLastPathComponent()
            var final = target
            var rc = FileOps.rename(temp, to: target)
            if rc == EEXIST {
                final = dir.appendingPathComponent(FileNaming.keepBothName(for: target.lastPathComponent) { FileOps.exists(dir.appendingPathComponent($0)) })
                rc = FileOps.rename(temp, to: final)
            }
            return (final, rc)
        }
        if outcome.1 != 0 {
            fail(item, outcome.1, action)
            await blocking { FileOps.removeTree(temp) }
            return nil
        }
        return outcome.0
    }
}

/// Runs a command-line tool, stopping it if the job is cancelled. Returns 0, ECANCELED, or EIO.
enum Tool {
    static func run(_ path: String, _ args: [String], control: JobControl) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ENOENT }
        while p.isRunning {
            if control.cancelled.load(ordering: .relaxed) {
                p.terminate()
                p.waitUntilExit()
                return ECANCELED
            }
            usleep(20_000)
        }
        return p.terminationStatus == 0 ? 0 : EIO
    }
}

// MARK: Quick Actions

extension Execution {
    func rotate(_ items: [URL], clockwise: Bool) async {
        update {
            $0.itemsTotal = items.count
            $0.phase = .running
        }
        for item in items {
            guard control.checkpoint() else { break }
            update { $0.currentName = item.lastPathComponent }
            let rc: Int32 = await blocking {
                do {
                    try QuickActions.rotate(item, clockwise: clockwise)
                    return 0
                } catch let f as QuickActions.Failure {
                    return f.code
                } catch {
                    return Self.errno(of: error as NSError)
                }
            }
            if rc == 0 {
                result.record(.rotated(item, clockwise: clockwise))
                result.changedFolders.insert(item.deletingLastPathComponent())
            } else {
                fail(item, rc, "rotate")
            }
            update { $0.itemsDone += 1 }
        }
    }

    func createPDF(_ items: [URL]) async {
        guard let first = items.first else { return }
        update {
            $0.itemsTotal = 1
            $0.phase = .running
            $0.currentName = first.lastPathComponent
        }
        let dir = first.deletingLastPathComponent()
        let outcome: Result<URL, NSError> = await blocking {
            let base = (first.lastPathComponent as NSString).deletingPathExtension
            let name = FileNaming.keepBothFreeName("\(base).pdf") { FileOps.exists(dir.appendingPathComponent($0)) }
            let target = dir.appendingPathComponent(name)
            do {
                try QuickActions.createPDF(from: items, at: target)
                return .success(target)
            } catch let f as QuickActions.Failure {
                return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(f.code)))
            } catch {
                return .failure(error as NSError)
            }
        }
        switch outcome {
        case .success(let pdf):
            result.record(.created(pdf))
            result.changedFolders.insert(dir)
        case .failure(let error):
            fail(first, Self.errno(of: error), "make a PDF from")
        }
        update { $0.itemsDone = 1 }
    }
}
