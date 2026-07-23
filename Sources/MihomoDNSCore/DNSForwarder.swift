import Darwin
import Foundation

public enum DNSForwardingError: Error, CustomStringConvertible {
    case noUpstream
    case resolveFailed(String)
    case socketFailed(Int32)
    case connectFailed(Int32)
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case invalidTCPResponse
    case responseMismatch
    case allUpstreamsFailed
    case originalDNSForbidden

    public var description: String {
        switch self {
        case .noUpstream: return "no upstream DNS server is available"
        case .resolveFailed(let host): return "cannot resolve numeric upstream \(host)"
        case .socketFailed(let code): return "socket failed errno=\(code)"
        case .connectFailed(let code): return "connect failed errno=\(code)"
        case .sendFailed(let code): return "send failed errno=\(code)"
        case .receiveFailed(let code): return "receive failed errno=\(code)"
        case .invalidTCPResponse: return "invalid TCP DNS response"
        case .responseMismatch: return "DNS response transaction ID does not match query"
        case .allUpstreamsFailed: return "all upstream DNS servers failed"
        case .originalDNSForbidden: return "original DNS fallback is forbidden for this query"
        }
    }
}

enum SocketDNSClient {
    static func queryTCP(
        _ query: Data,
        endpoint: Endpoint,
        timeoutMilliseconds: Int,
        interfaceName: String?
    ) throws -> Data {
        try DNSMessage.validate(query)
        let response = try exchange(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: timeoutMilliseconds,
            interfaceName: interfaceName,
            socketType: SOCK_STREAM,
            protocolNumber: IPPROTO_TCP
        )
        try validateResponse(response, query: query)
        return response
    }

    static func query(
        _ query: Data,
        endpoint: Endpoint,
        timeoutMilliseconds: Int,
        interfaceName: String?
    ) throws -> Data {
        let udp = try exchange(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: timeoutMilliseconds,
            interfaceName: interfaceName,
            socketType: SOCK_DGRAM,
            protocolNumber: IPPROTO_UDP
        )
        try validateResponse(udp, query: query)
        if DNSMessage.isTruncated(udp) {
            let tcp = try exchange(
                query,
                endpoint: endpoint,
                timeoutMilliseconds: timeoutMilliseconds,
                interfaceName: interfaceName,
                socketType: SOCK_STREAM,
                protocolNumber: IPPROTO_TCP
            )
            try validateResponse(tcp, query: query)
            return tcp
        }
        return udp
    }

    private static func validateResponse(_ response: Data, query: Data) throws {
        try DNSMessage.validate(response)
        guard response.prefix(2) == query.prefix(2) else {
            throw DNSForwardingError.responseMismatch
        }
    }

    private static func exchange(
        _ query: Data,
        endpoint: Endpoint,
        timeoutMilliseconds: Int,
        interfaceName: String?,
        socketType: Int32,
        protocolNumber: Int32
    ) throws -> Data {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = socketType
        hints.ai_protocol = protocolNumber
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result)
        guard status == 0, let first = result else {
            throw DNSForwardingError.resolveFailed(endpoint.host)
        }
        defer { freeaddrinfo(first) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        var lastError: Error = DNSForwardingError.connectFailed(ECONNREFUSED)
        while let address = candidate {
            do {
                let fd = Darwin.socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
                guard fd >= 0 else { throw DNSForwardingError.socketFailed(errno) }
                defer { Darwin.close(fd) }
                configureTimeout(fd: fd, timeoutMilliseconds: timeoutMilliseconds)
                try bind(fd: fd, family: address.pointee.ai_family, interfaceName: interfaceName)
                guard Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
                    throw DNSForwardingError.connectFailed(errno)
                }
                if socketType == SOCK_STREAM {
                    return try exchangeTCP(fd: fd, query: query)
                }
                return try exchangeUDP(fd: fd, query: query)
            } catch {
                lastError = error
                candidate = address.pointee.ai_next
            }
        }
        throw lastError
    }

    private static func configureTimeout(fd: Int32, timeoutMilliseconds: Int) {
        var timeout = timeval(
            tv_sec: timeoutMilliseconds / 1_000,
            tv_usec: Int32((timeoutMilliseconds % 1_000) * 1_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func bind(fd: Int32, family: Int32, interfaceName: String?) throws {
        guard let interfaceName, !interfaceName.isEmpty else { return }
        var index = if_nametoindex(interfaceName)
        guard index != 0 else { return }
        let result: Int32
        if family == AF_INET6 {
            result = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        } else {
            result = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        if result != 0 {
            throw DNSForwardingError.socketFailed(errno)
        }
    }

    private static func exchangeUDP(fd: Int32, query: Data) throws -> Data {
        let sent = query.withUnsafeBytes { bytes in
            Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == query.count else {
            throw DNSForwardingError.sendFailed(errno)
        }
        var response = [UInt8](repeating: 0, count: DNSMessage.maximumWireLength)
        let received = Darwin.recv(fd, &response, response.count, 0)
        guard received > 0 else {
            throw DNSForwardingError.receiveFailed(errno)
        }
        return Data(response.prefix(received))
    }

    private static func exchangeTCP(fd: Int32, query: Data) throws -> Data {
        var frame = Data([UInt8(query.count >> 8), UInt8(query.count & 0xff)])
        frame.append(query)
        try writeAll(fd: fd, data: frame)
        let lengthBytes = try readExactly(fd: fd, count: 2)
        let length = (Int(lengthBytes[0]) << 8) | Int(lengthBytes[1])
        guard length >= 12, length <= DNSMessage.maximumWireLength else {
            throw DNSForwardingError.invalidTCPResponse
        }
        return try readExactly(fd: fd, count: length)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
                guard written > 0 else { throw DNSForwardingError.sendFailed(errno) }
                offset += written
            }
        }
    }

    private static func readExactly(fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { bytes in
            while offset < count {
                let received = Darwin.recv(fd, bytes.baseAddress?.advanced(by: offset), count - offset, 0)
                guard received > 0 else { throw DNSForwardingError.receiveFailed(errno) }
                offset += received
            }
        }
        return result
    }
}
