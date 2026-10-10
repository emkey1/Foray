import AppKit
import Foundation
import Testing

@testable import RFFileSystem
@testable import RFOperations
@testable import RFUI

/// Stands in for macOS's service registration: nothing is ever registered on this machine.
@MainActor
final class FakeHelperRegistration: HelperRegistration {
    var isBundled = true
    var state = AdministratorAccess.Status.off
    /// What macOS answers when asked to register: allowed straight away, or waiting for the user.
    var registersAs = AdministratorAccess.Status.on
    var registerError: Error?
    var calls: [String] = []

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        state = registersAs
        // macOS reports "waiting for approval" by throwing, having registered all the same.
        if registersAs == .needsApproval { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
    }

    func unregister() throws {
        calls.append("unregister")
        state = .off
    }
}

extension UISerial {
    @MainActor
    @Suite(.serialized) final class AdvancedSettingsTests {
        let base = TestDirs.make("advanced")
        let registration = FakeHelperRegistration()
        let center: OperationCenter
        private let savedRegistration = AdministratorAccess.registration
        private let savedTool = CommandLineTool.tool, savedLink = CommandLineTool.link
        private let savedCenter = OperationCenter.shared

        init() throws {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            center = OperationCenter(journal: OperationJournal(store: AppSupportStore(directory: base.appendingPathComponent("journal"))),
                                     trash: { $0 })
            OperationCenter.shared = center
            AdministratorAccess.registration = registration
            // A stand-in tool and a private "bin" folder.
            let tool = base.appendingPathComponent("Foray.app/Contents/Helpers/foray")
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            CommandLineTool.tool = tool
            CommandLineTool.link = base.appendingPathComponent("bin/foray")
        }

        isolated deinit {
            AdministratorAccess.registration = savedRegistration
            CommandLineTool.tool = savedTool
            CommandLineTool.link = savedLink
            OperationCenter.shared = savedCenter
            chmod(base.appendingPathComponent("bin").path, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        // MARK: Administrator access

        @Test func offUntilTheUserTurnsItOn() {
            #expect(AdministratorAccess.status == .off && !AdministratorAccess.isOn)
            AdministratorAccess.apply(to: center)                  // what launch does
            #expect(center.elevation == nil)
            #expect(registration.calls.isEmpty)                    // nothing registered by itself
            _ = SettingsPaneModel()                                // nor by opening Settings
            #expect(registration.calls.isEmpty)
        }

        @Test func theSwitchAsksThenRegistersAndTurningOffRemoves() {
            let model = SettingsPaneModel()
            model.setAdministratorAccess(true, confirm: { false })           // Cancel
            #expect(registration.calls.isEmpty && model.administratorAccess == .off && center.elevation == nil)

            model.setAdministratorAccess(true, confirm: { true })
            #expect(registration.calls == ["register"])
            #expect(model.administratorAccess == .on && model.administratorNote == nil)
            #expect(center.elevation != nil)                                 // the engine can reach the helper

            model.setAdministratorAccess(false)
            #expect(registration.calls == ["register", "unregister"])
            #expect(model.administratorAccess == .off && center.elevation == nil)
        }

        @Test func waitingForApprovalSaysWhatToDo() {
            registration.registersAs = .needsApproval
            let model = SettingsPaneModel()
            model.setAdministratorAccess(true, confirm: { true })
            #expect(model.administratorAccess == .needsApproval)
            #expect(model.administratorNote == AdministratorAccess.approvalNote)
            // The user allows it in System Settings and comes back.
            registration.state = .on
            model.refreshAccess()
            #expect(model.administratorAccess == .on && model.administratorNote == nil)
        }

        @Test func aFailureToRegisterIsReportedAndLeavesItOff() {
            registration.registerError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "not signed"])
            let model = SettingsPaneModel()
            model.setAdministratorAccess(true, confirm: { true })
            #expect(model.administratorAccess == .off && center.elevation == nil)
            #expect(model.administratorNote?.contains("not signed") == true)
        }

        @Test func buildsWithoutTheHelperCantTurnItOn() {
            registration.isBundled = false
            registration.state = .unavailable
            #expect(AdministratorAccess.turnOn() != nil)
            #expect(registration.calls.isEmpty && center.elevation == nil)
        }

        @Test func permissionErrorsPointToTheSettingOnlyWhenItsOff() {
            var denied = OperationResult()
            denied.errors = [ItemError(url: base, code: EACCES, action: "copy")]
            var other = OperationResult()
            other.errors = [ItemError(url: base, code: ENOSPC, action: "copy")]
            #expect(AdministratorAccess.hint(for: denied)?.contains("Settings › Advanced") == true)
            #expect(AdministratorAccess.hint(for: other) == nil)
            registration.state = .on
            #expect(AdministratorAccess.hint(for: denied) == nil)
        }

        // MARK: The command-line tool link

        @Test func installLinksToTheToolInsideTheAppAndRemoveTakesItAway() throws {
            #expect(CommandLineTool.status == .notInstalled)
            #expect(CommandLineTool.install() == .done)
            #expect(CommandLineTool.status == .installed)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: CommandLineTool.link.path) == CommandLineTool.tool.path)
            #expect(CommandLineTool.install() == .done)                      // again: nothing to do
            #expect(CommandLineTool.uninstall())
            #expect(CommandLineTool.status == .notInstalled)
            #expect(FileManager.default.fileExists(atPath: CommandLineTool.tool.path))   // the tool itself stays
        }

        @Test func aLinkToAnotherCopyIsReplacedButARealFileIsLeftAlone() throws {
            let bin = CommandLineTool.link.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: CommandLineTool.link.path, withDestinationPath: "/somewhere/else/foray")
            #expect(CommandLineTool.status == .elsewhere("/somewhere/else/foray"))
            #expect(!CommandLineTool.uninstall())                            // not ours to remove
            #expect(CommandLineTool.install() == .done && CommandLineTool.status == .installed)

            try FileManager.default.removeItem(at: CommandLineTool.link)
            FileManager.default.createFile(atPath: CommandLineTool.link.path, contents: Data("someone's script".utf8))
            #expect(CommandLineTool.status == .blocked)
            if case .failed = CommandLineTool.install() {} else { Issue.record("a real file was replaced") }
            #expect(try String(contentsOf: CommandLineTool.link, encoding: .utf8) == "someone's script")
        }

        @Test func aProtectedFolderGivesTheTerminalCommandInstead() throws {
            let bin = CommandLineTool.link.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            chmod(bin.path, 0o555)
            let model = SettingsPaneModel()
            model.installCommandLineTool()
            #expect(model.commandLineTool == .notInstalled)
            let command = try #require(model.commandLineCommand)
            #expect(command == "sudo mkdir -p '\(bin.path)' && sudo ln -sf '\(CommandLineTool.tool.path)' '\(CommandLineTool.link.path)'")
        }

        @Test func buildsWithoutTheToolSaySo() {
            CommandLineTool.tool = base.appendingPathComponent("nope")
            #expect(CommandLineTool.status == .unavailable)
            if case .failed = CommandLineTool.install() {} else { Issue.record("installed a missing tool") }
        }
    }
}
