import Foundation

public struct CredentialProxyScope: Hashable, Sendable {
    public let host: String
    public let port: Int
    public init(_ host: String, _ port: Int) { self.host = host; self.port = port }
}

public struct CredentialProxyBinding: Sendable {
    public let scope: CredentialProxyScope
    public let value: String
    public let header: String
    public let prefix: String
    public let scheme: String
    public init(scope: CredentialProxyScope, value: String, header: String = "Authorization", prefix: String = "Bearer ", scheme: String = "https") {
        self.scope = scope; self.value = value; self.header = header; self.prefix = prefix; self.scheme = scheme
    }
}

public struct CredentialProxyForward: Sendable {
    public let host: String
    public let port: Int
    public let path: String
    public let headers: [String: String]
}

public enum CredentialProxyPolicy {
    public enum Rejection: Error { case method, target, scope, header, credential }
    private static let strip: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "authorization", "x-api-key", "cookie", "host", "content-length", "expect", "accept-encoding", "x-nvx-proxy-capability"]
    private static func invalid(_ value: String) -> Bool { value.contains("\r") || value.contains("\n") || value.contains("\0") }

    public static func prepare(method: String, target: String, headers: [(String, String)], allowed: Set<CredentialProxyScope>, bindings: [CredentialProxyBinding]) throws -> CredentialProxyForward {
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else { throw Rejection.method }
        guard !invalid(target) else { throw Rejection.target }
        var absolute = target
        for scheme in ["https", "http"] where target.hasPrefix("/\(scheme)/") {
            absolute = "\(scheme)://" + target.dropFirst(scheme.count + 2)
        }
        guard let components = URLComponents(string: absolute), let scheme = components.scheme,
              ["http", "https"].contains(scheme), let rawHost = components.host,
              components.user == nil, components.password == nil, components.fragment == nil else { throw Rejection.target }
        var host = rawHost.lowercased()
        while host.last == "." { host.removeLast() }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        let scope = CredentialProxyScope(host, port)
        guard allowed.contains(scope) else { throw Rejection.scope }
        var lowered: [String: String] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            guard lowered[key] == nil, !invalid(name + value) else { throw Rejection.header }
            lowered[key] = value
        }
        let connection = Set((lowered["connection"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var forwarded = lowered.filter { !strip.union(connection).contains($0.key) }
        forwarded["accept-encoding"] = "identity"
        for binding in bindings where binding.scope == scope {
            let forbidden = strip.subtracting(["authorization", "x-api-key", "cookie"])
            guard binding.scheme == scheme, !forbidden.contains(binding.header.lowercased()), !binding.value.isEmpty, !invalid(binding.value + binding.header + binding.prefix) else { throw Rejection.credential }
            forwarded[binding.header.lowercased()] = binding.prefix + binding.value
        }
        let path = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        return CredentialProxyForward(host: host, port: port, path: path, headers: forwarded)
    }
}
