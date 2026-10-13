import Darwin
import Foundation

/// Finds Windows-style file servers on the local network: machines that answer NetBIOS name
/// service queries (UDP port 137) rather than announcing themselves with Bonjour. That's most
/// Samba servers on Linux boxes and older NAS units, and Windows PCs with NetBIOS on; Finder shows
/// them in Network as a PC.
///
/// It works the way `nmblookup -S '*'` does: ask everyone on each local network for the wildcard
/// name, then ask each machine that answers for its name table and take the file-server name.
public enum NetBIOSDiscovery {
    public struct Host: Hashable, Sendable {
        /// The machine's NetBIOS name, as it gives it (usually upper case).
        public var name: String
        public var workgroup: String?
        /// Its IPv4 address, for connecting.
        public var address: String

        public init(name: String, workgroup: String? = nil, address: String) {
            self.name = name
            self.workgroup = workgroup
            self.address = address
        }
    }

    public struct Target: Hashable, Sendable {
        public var address: String
        public var port: UInt16
        public init(address: String, port: UInt16 = 137) {
            self.address = address
            self.port = port
        }
    }

    static let typeName: UInt16 = 0x0020     // NB: a name query
    static let typeStatus: UInt16 = 0x0021   // NBSTAT: the name table

    // MARK: Packets (RFC 1002)

    /// The wildcard name "*", padded with NULs, in NetBIOS's first-level encoding: each byte
    /// becomes two letters, and the 32 letters are sent as one DNS-style label.
    static var wildcardName: [UInt8] {
        var raw = [UInt8](repeating: 0, count: 16)
        raw[0] = UInt8(ascii: "*")
        var out: [UInt8] = [32]
        for byte in raw {
            out.append(UInt8(ascii: "A") + (byte >> 4))
            out.append(UInt8(ascii: "A") + (byte & 0x0F))
        }
        out.append(0)
        return out
    }

    /// A question for the wildcard name. `broadcast` asks every machine on the network.
    static func query(id: UInt16, type: UInt16, broadcast: Bool) -> Data {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)]
        p += broadcast ? [0x01, 0x10] : [0x00, 0x00]   // recursion desired + broadcast, or a plain query
        p += [0, 1, 0, 0, 0, 0, 0, 0]                  // one question, nothing else
        p += wildcardName
        p += [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]   // type, class IN
        return Data(p)
    }

    enum Reply: Equatable {
        /// "I have that name": the machine exists; ask it for its table.
        case present
        /// Its name table: the file-server name and workgroup, if it has them.
        case status(name: String?, workgroup: String?)
    }

    /// Reads a reply. Nil for anything that isn't an answer to one of our questions.
    static func parse(_ data: Data) -> Reply? {
        let b = [UInt8](data)
        guard b.count >= 12, b[2] & 0x80 != 0 else { return nil }           // must be a response
        guard b[3] & 0x0F == 0 else { return nil }                           // with no error
        let answers = Int(b[6]) << 8 | Int(b[7])
        guard answers >= 1 else { return nil }
        var i = 12
        // Skip any echoed question, then the answer's name (a label sequence or a pointer).
        func skipName() -> Bool {
            while i < b.count {
                let length = Int(b[i])
                if length & 0xC0 == 0xC0 { i += 2; return i <= b.count }
                i += 1
                if length == 0 { return true }
                i += length
            }
            return false
        }
        let questions = Int(b[4]) << 8 | Int(b[5])
        for _ in 0..<questions {
            guard skipName() else { return nil }
            i += 4
        }
        guard skipName(), i + 10 <= b.count else { return nil }
        let type = UInt16(b[i]) << 8 | UInt16(b[i + 1])
        let length = Int(b[i + 8]) << 8 | Int(b[i + 9])
        i += 10
        guard i + length <= b.count else { return nil }
        if type == typeName { return .present }
        guard type == typeStatus, length >= 1 else { return nil }
        let count = Int(b[i])
        i += 1
        var server: String?, workgroup: String?
        for _ in 0..<count {
            guard i + 18 <= b.count else { break }
            let name = String(decoding: b[i..<(i + 15)], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let suffix = b[i + 15]
            let isGroup = b[i + 16] & 0x80 != 0
            i += 18
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { continue }
            switch (suffix, isGroup) {
            case (0x20, false): server = server ?? name          // the file server service
            case (0x00, true): workgroup = workgroup ?? name
            default: break
            }
        }
        // Only machines that share files are of interest; one without the file-server name isn't listed.
        return .status(name: server, workgroup: workgroup)
    }

    // MARK: Scanning

    /// The broadcast address of each local IPv4 network this Mac is on (not loopback, not VPN-style
    /// point-to-point links).
    public static func broadcastTargets() -> [Target] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var out: [Target] = []
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = entry.pointee.ifa_dstaddr else { continue }
            let text = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { string(for: $0.pointee.sin_addr) }
            if let text, text != "0.0.0.0", !out.contains(where: { $0.address == text }) { out.append(Target(address: text)) }
        }
        return out
    }

    /// This Mac's own IPv4 addresses (it answers its own question when it shares files).
    public static func localAddresses() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var out = Set<String>()
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            if let text = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { string(for: $0.pointee.sin_addr) }) { out.insert(text) }
        }
        return out
    }

    private static func string(for address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func socketAddress(_ target: Target) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = target.port.bigEndian
        guard inet_pton(AF_INET, target.address, &address.sin_addr) == 1 else { return nil }
        return address
    }

    /// Asks `targets` (by default, every local network's broadcast address) and returns the file
    /// servers that answered within `timeout`, sorted by name. Blocks for that long: call it off
    /// the main thread (`scan` does).
    public static func scanBlocking(targets: [Target]? = nil, timeout: TimeInterval = 2.0) -> [Host] {
        let targets = targets ?? broadcastTargets()
        guard !targets.isEmpty else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        func send(_ packet: Data, to target: sockaddr_in) {
            var target = target
            packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        let id = UInt16.random(in: 1...UInt16.max)
        for target in targets.compactMap(socketAddress) {
            // Both questions: some machines answer one when broadcast, some the other.
            send(query(id: id, type: typeName, broadcast: true), to: target)
            send(query(id: id, type: typeStatus, broadcast: true), to: target)
        }

        var hosts: [String: Host] = [:]      // by address
        var asked = Set<String>()            // machines already asked for their table
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0 else { break }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0, let source = string(for: from.sin_addr) else { continue }
            switch parse(Data(buffer[0..<count])) {
            case .present:
                // It exists; ask it directly (on the port it answered from) for its names.
                if asked.insert(source).inserted, hosts[source] == nil {
                    send(query(id: id, type: typeStatus, broadcast: false), to: from)
                }
            case .status(let name?, let workgroup):
                hosts[source] = Host(name: name, workgroup: workgroup, address: source)
            case .status(nil, _), nil:
                break
            }
        }
        return hosts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func scan(targets: [Target]? = nil, timeout: TimeInterval = 2.0) async -> [Host] {
        await Task.detached(priority: .utility) { scanBlocking(targets: targets, timeout: timeout) }.value
    }
}
