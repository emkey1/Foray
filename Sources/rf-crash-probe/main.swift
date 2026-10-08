// Test helper for the kill -9 test: copies <source> into <destination folder> using the real
// engine and journal (stored in <journal folder>), then exits. The test kills it mid-copy.
import Foundation
import RFFileSystem
import RFOperations

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: rf-crash-probe <source> <destination folder> <journal folder>\n".utf8))
    exit(2)
}
let journal = OperationJournal(store: AppSupportStore(directory: URL(fileURLWithPath: args[3])))
let center = OperationCenter(journal: journal, trash: Trash.system)
let result = await center.run(.copy([URL(fileURLWithPath: args[1])], to: URL(fileURLWithPath: args[2])))
print(result.errors.isEmpty ? "done" : "errors: \(result.errors.map(\.message))")
