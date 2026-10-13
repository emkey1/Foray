import Darwin
import Foundation
import Testing

@testable import RFFileSystem

/// Windows-style (NetBIOS) server discovery. Nothing here touches the real network: the "server"
/// is a socket on this Mac's loopback address that answers like a Samba machine.
@Suite struct NetBIOSDiscoveryTests {
    /// A reply to the wildcard question: the header, the name echoed, then the answer data.
    static func reply(id: UInt16 = 7, type: UInt16, data: [UInt8], error: UInt8 = 0) -> Data {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x85, error, 0, 0, 0, 1, 0, 0, 0, 0]
        p += NetBIOSDiscovery.wildcardName
        p += [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0, 0, UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
        return Data(p + data)
    }

    /// A name table: (name, suffix, is it a group name).
    static func table(_ names: [(String, UInt8, Bool)]) -> [UInt8] {
        var d: [UInt8] = [UInt8(names.count)]
        for (name, suffix, group) in names {
            d += Array(name.padding(toLength: 15, withPad: " ", startingAt: 0).utf8) + [suffix, group ? 0x84 : 0x04, 0x00]
        }
        return d + [UInt8](repeating: 0, count: 46)   // the statistics block that follows
    }

    static let sambaTable = table([("RPI", 0x00, false), ("RPI", 0x03, false), ("RPI", 0x20, false),
                                   ("\u{01}\u{02}__MSBROWSE__\u{02}", 0x01, true), ("WORKGROUP", 0x00, true), ("WORKGROUP", 0x1E, true)])

    @Test func theWildcardQuestionIsWhatOtherToolsSend() {
        // "*" and fifteen NULs, two letters per byte: CK then thirty As.
        #expect(String(decoding: NetBIOSDiscovery.wildcardName.dropFirst().dropLast(), as: UTF8.self) == "CK" + String(repeating: "A", count: 30))
        let broadcast = [UInt8](NetBIOSDiscovery.query(id: 0x1234, type: NetBIOSDiscovery.typeName, broadcast: true))
        #expect(broadcast.count == 50)
        #expect(Array(broadcast[0..<12]) == [0x12, 0x34, 0x01, 0x10, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(Array(broadcast.suffix(4)) == [0x00, 0x20, 0x00, 0x01])
        let direct = [UInt8](NetBIOSDiscovery.query(id: 1, type: NetBIOSDiscovery.typeStatus, broadcast: false))
        #expect(Array(direct[2..<4]) == [0, 0] && Array(direct.suffix(4)) == [0x00, 0x21, 0x00, 0x01])
    }

    @Test func readsAServersNameTable() {
        #expect(NetBIOSDiscovery.parse(Self.reply(type: 0x21, data: Self.sambaTable)) == .status(name: "RPI", workgroup: "WORKGROUP"))
        // A machine that doesn't share files (no file-server name) is recognized but not listed.
        let client = Self.table([("LAPTOP", 0x00, false), ("HOME", 0x00, true)])
        #expect(NetBIOSDiscovery.parse(Self.reply(type: 0x21, data: client)) == .status(name: nil, workgroup: "HOME"))
        // "I have that name" just means: ask me.
        #expect(NetBIOSDiscovery.parse(Self.reply(type: 0x20, data: [0, 0, 192, 168, 1, 20])) == .present)
    }

    @Test func ignoresAnythingThatIsntAnAnswer() {
        #expect(NetBIOSDiscovery.parse(Data()) == nil)
        #expect(NetBIOSDiscovery.parse(Data([1, 2, 3])) == nil)
        #expect(NetBIOSDiscovery.parse(NetBIOSDiscovery.query(id: 1, type: 0x21, broadcast: true)) == nil)      // a question
        #expect(NetBIOSDiscovery.parse(Self.reply(type: 0x21, data: Self.sambaTable, error: 0x03)) == nil)       // an error reply
        // Cut short anywhere, it's nil or a partial table, never a crash.
        let whole = [UInt8](Self.reply(type: 0x21, data: Self.sambaTable))
        for length in 0..<whole.count { _ = NetBIOSDiscovery.parse(Data(whole[0..<length])) }
        // A table claiming more names than it holds.
        var lying = Self.sambaTable
        lying[0] = 200
        #expect(NetBIOSDiscovery.parse(Self.reply(type: 0x21, data: lying)) == .status(name: "RPI", workgroup: "WORKGROUP"))
        // Names with control characters aren't shown.
        #expect(NetBIOSDiscovery.parse(Self.reply(type: 0x21, data: Self.table([("BAD\u{07}NAME", 0x20, false)]))) == .status(name: nil, workgroup: nil))
    }

    /// A stand-in server on 127.0.0.1: answers the name question with "present" and the table
    /// question with its names, like Samba. Returns the port it listens on.
    private func startServer(answersBroadcastTable: Bool, table: [UInt8]) throws -> (port: UInt16, stop: @Sendable () -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) } }
                guard n >= 50 else { break }                          // closed
                let id = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
                let isBroadcast = buffer[3] & 0x10 != 0
                let type = UInt16(buffer[n - 4]) << 8 | UInt16(buffer[n - 3])
                var answer: Data?
                if type == 0x20 { answer = Self.reply(id: id, type: 0x20, data: [0, 0, 127, 0, 0, 1]) }
                if type == 0x21, !isBroadcast || answersBroadcastTable { answer = Self.reply(id: id, type: 0x21, data: table) }
                if let answer {
                    answer.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, fromLength) } }
                    }
                }
            }
        }
        return (port, { shutdown(fd, SHUT_RDWR); close(fd) })
    }

    @Test func findsAServerThatOnlyAnswersWhenAskedDirectly() async throws {
        // Like many machines: says "present" to the broadcast, gives its table only one-to-one.
        let server = try startServer(answersBroadcastTable: false, table: Self.sambaTable)
        defer { server.stop() }
        let found = await NetBIOSDiscovery.scan(targets: [.init(address: "127.0.0.1", port: server.port)], timeout: 1.0)
        #expect(found == [NetBIOSDiscovery.Host(name: "RPI", workgroup: "WORKGROUP", address: "127.0.0.1")])
    }

    @Test func findsAServerThatAnswersTheBroadcastTableQuestion() async throws {
        let server = try startServer(answersBroadcastTable: true, table: Self.sambaTable)
        defer { server.stop() }
        let found = await NetBIOSDiscovery.scan(targets: [.init(address: "127.0.0.1", port: server.port)], timeout: 1.0)
        #expect(found.map(\.name) == ["RPI"])
    }

    @Test func machinesThatDontShareFilesArentListedAndSilenceIsEmpty() async throws {
        let server = try startServer(answersBroadcastTable: true, table: Self.table([("LAPTOP", 0x00, false), ("HOME", 0x00, true)]))
        defer { server.stop() }
        #expect(await NetBIOSDiscovery.scan(targets: [.init(address: "127.0.0.1", port: server.port)], timeout: 0.5).isEmpty)
        // Nobody there at all: comes back empty after the wait, without error.
        #expect(await NetBIOSDiscovery.scan(targets: [.init(address: "127.0.0.1", port: 9)], timeout: 0.3).isEmpty)
        #expect(await NetBIOSDiscovery.scan(targets: [], timeout: 5).isEmpty)
    }

    @Test func broadcastAddressesLookLikeAddresses() {
        for target in NetBIOSDiscovery.broadcastTargets() {
            #expect(target.port == 137)
            #expect(target.address.split(separator: ".").count == 4 && !target.address.hasPrefix("127."))
        }
    }
}
