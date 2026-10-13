import Darwin
import dnssd
import Foundation

/// Looks up the addresses behind a Bonjour file-server name, so a machine that's found both by
/// Bonjour and by `NetBIOSDiscovery` (under a different name) can be recognized as one machine.
public enum BonjourResolver {
    /// The IPv4 addresses of the SMB service called `name` on the local network; empty if it
    /// doesn't answer within `timeout`. Blocks: call it off the main thread.
    public static func addresses(forSMBService name: String, timeout: TimeInterval = 1.0) -> Set<String> {
        machine(forSMBService: name, timeout: timeout).addresses
    }

    /// The machine behind an SMB service: its host name without the domain ("anna" for
    /// "anna.local."), which is also where its Windows-style name comes from, and its addresses
    /// (a machine on both Wi-Fi and Ethernet has more than are returned here).
    public static func machine(forSMBService name: String, timeout: TimeInterval = 1.0) -> (host: String?, addresses: Set<String>) {
        guard let host = hostName(service: name, type: "_smb._tcp", timeout: timeout) else { return (nil, []) }
        let label = host.split(separator: ".").first.map(String.init)
        return (label, ipv4Addresses(of: host))
    }

    /// The host a service runs on ("anna.local."), from its SRV record.
    static func hostName(service: String, type: String, timeout: TimeInterval) -> String? {
        final class Box { var host: String? }
        let box = Box()
        var ref: DNSServiceRef?
        let callback: DNSServiceResolveReply = { _, _, _, error, _, hostTarget, _, _, _, context in
            guard error == kDNSServiceErr_NoError, let hostTarget, let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().host = String(cString: hostTarget)
        }
        let started = DNSServiceResolve(&ref, 0, 0, service, type, "local.", callback, Unmanaged.passUnretained(box).toOpaque())
        guard started == kDNSServiceErr_NoError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        // Wait for the answer on the service's socket, then let it call back.
        var poller = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
        DNSServiceProcessResult(ref)
        return withExtendedLifetime(box) { box.host }
    }

    static func ipv4Addresses(of host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var out = Set<String>()
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                out.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return out
    }
}
