import Foundation
import Testing

@testable import RFModel
@testable import RFOperations

/// Deterministic random numbers, so a failing seed can be replayed.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// DESIGN.md §8: random sequences of operations, then undo everything → the tree must be exactly
/// what it was; redo everything → exactly the end state again. No temporary files, ever.
@MainActor
@Suite struct FuzzTests {
    /// 12 by default; RF_FUZZ_SEEDS=200 for a long run.
    nonisolated static let seeds: [UInt64] = Array(1...UInt64(ProcessInfo.processInfo.environment["RF_FUZZ_SEEDS"].flatMap(Int.init) ?? 12))

    @Test(arguments: seeds)
    func randomOperationsUndoToTheStart(seed: UInt64) async throws {
        let s = try Sandbox()
        var rng = SeededRNG(state: seed)
        for path in ["docs/a.txt", "docs/b.md", "docs/deep/c.txt", "docs/deep/deeper/d.bin", "pics/p1.jpg", "pics/p2.jpg",
                     "pics/.hidden", "notes.txt", "Empty Folder/.keep", "x/y/z/leaf.txt"] {
            s.file(path, "content of \(path) \(seed)")
        }
        let initial = s.tree()
        let answers: [ConflictResolution] = [.keepBoth, .skip, .replace]

        func items() -> [URL] { s.tree().keys.sorted().map { s.work.appendingPathComponent($0) } }
        func folders() -> [URL] { [s.work] + s.tree().filter { $0.value == "<dir>" }.keys.sorted().map { s.work.appendingPathComponent($0) } }

        var log: [String] = []
        for step in 0..<25 {
            let all = items()
            guard !all.isEmpty else { break }
            let pick = all.randomElement(using: &rng)!
            let pick2 = Array(all.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)))
            let folder = folders().randomElement(using: &rng)!
            s.answers = (0..<5).map { _ in ConflictAnswer(answers.randomElement(using: &rng)!) }
            let request: OperationRequest
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: request = .copy(pick2, to: folder)
            case 1: request = .move(pick2, to: folder)
            case 2: request = .duplicate(pick2)
            case 3: request = .rename(pick, to: "renamed-\(step)\(pick.pathExtension.isEmpty ? "" : "." + pick.pathExtension)")
            case 4: request = .trash(pick2)
            case 5: request = .newFolder(in: folder)
            default:
                let siblings = all.filter { $0.deletingLastPathComponent() == folder }
                request = .newFolder(in: folder, moving: Array(siblings.prefix(2)))
            }
            log.append("\(step): \(request.undoName) \(request.title)")
            _ = await s.run(request)
            #expect(!s.tree().keys.contains { $0.contains(OperationJournal.marker) }, "temp file left after step \(step), seed \(seed)")
            #expect(s.journal.pending.isEmpty)
        }
        let final = s.tree()

        while s.center.undoManager.canUndo { await s.undo() }
        #expect(s.tree() == initial, "undo all, seed \(seed):\n\(log.joined(separator: "\n"))")

        while s.center.undoManager.canRedo { await s.redo() }
        #expect(s.tree() == final, "redo all, seed \(seed):\n\(log.joined(separator: "\n"))")
    }
}
