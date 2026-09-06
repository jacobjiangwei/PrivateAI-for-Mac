import Darwin
import Foundation

public enum BrowserDestinationPolicyError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case disallowedHost(String)
    case resolutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "A public HTTPS URL is required."
        case .disallowedHost(let host):
            "The host '\(host)' is not a public web destination."
        case .resolutionFailed(let host):
            "The host '\(host)' could not be resolved to a public address."
        }
    }
}

public enum BrowserDestinationPolicy {
    public static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw BrowserDestinationPolicyError.invalidURL
        }
        try validateStructure(url)
        return url
    }

    public static func validateStructure(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw BrowserDestinationPolicyError.invalidURL
        }
        let blockedNames = ["localhost", "localhost.localdomain", "metadata.google.internal"]
        let blockedSuffixes = [".localhost", ".local", ".internal", ".home.arpa"]
        guard !blockedNames.contains(host),
              !blockedSuffixes.contains(where: host.hasSuffix),
              isPublicIPAddressLiteral(host) else {
            throw BrowserDestinationPolicyError.disallowedHost(host)
        }
    }

    public static func validateResolvedDestination(_ url: URL) async throws {
        try validateStructure(url)
        guard let host = url.host?.lowercased() else {
            throw BrowserDestinationPolicyError.invalidURL
        }
        if isIPAddressLiteral(host) {
            return
        }
        let result = await Task.detached {
            resolve(host)
        }.value
        guard let addresses = result, !addresses.isEmpty else {
            throw BrowserDestinationPolicyError.resolutionFailed(host)
        }
        guard addresses.allSatisfy(isPublicIPAddressLiteral) else {
            throw BrowserDestinationPolicyError.disallowedHost(host)
        }
    }

    private static func resolve(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var current = result
        while let info = current?.pointee {
            if let address = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
                    addresses.append(String(decoding: buffer[..<end].map(UInt8.init), as: UTF8.self))
                }
            }
            current = info.ai_next
        }
        return addresses
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        let normalized = normalizedIPAddress(host)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, normalized, &ipv4) == 1
            || inet_pton(AF_INET6, normalized, &ipv6) == 1
    }

    private static func isPublicIPAddressLiteral(_ host: String) -> Bool {
        let normalized = normalizedIPAddress(host)
        var ipv4 = in_addr()
        if inet_pton(AF_INET, normalized, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            return isPublicIPv4(bytes)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPublicIPv4(Array(bytes[12...15]))
            }
            if bytes.allSatisfy({ $0 == 0 }) || bytes == Array(repeating: 0, count: 15) + [1] {
                return false
            }
            if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) {
                return false
            }
            return bytes[0] != 0xFF
        }
        return true
    }

    private static func normalizedIPAddress(_ host: String) -> String {
        var value = host
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        return value.split(separator: "%").first.map(String.init) ?? value
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1], bytes[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _):
            return false
        case (100, 64...127, _), (172, 16...31, _):
            return false
        case (192, 0, 0), (192, 0, 2), (198, 18...19, _), (198, 51, 100), (203, 0, 113):
            return false
        default:
            return bytes[0] < 224
        }
    }
}