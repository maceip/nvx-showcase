import Foundation
import Testing
@testable import NVXCore

struct ProxyGoldenTests {
    @Test func standaloneCredentialIsolation() throws {
        let scope = CredentialProxyScope("example.com", 443)
        let forwarded = try CredentialProxyPolicy.prepare(
            method: "POST", target: "https://EXAMPLE.com/submit?x=1",
            headers: [("Authorization", "Bearer caller"), ("Connection", "x-private"),
                      ("X-Private", "discard"), ("Content-Type", "application/json")],
            allowed: [scope], bindings: [CredentialProxyBinding(scope: scope, value: "host-secret")]
        )
        #expect(forwarded.host == "example.com")
        #expect(forwarded.port == 443)
        #expect(forwarded.path == "/submit?x=1")
        #expect(forwarded.headers["authorization"] == "Bearer host-secret")
        #expect(forwarded.headers["content-type"] == "application/json")
        #expect(forwarded.headers["x-private"] == nil)
        #expect(forwarded.headers["accept-encoding"] == "identity")
        #expect(throws: (any Error).self) {
            try CredentialProxyPolicy.prepare(method: "POST", target: "https://other.example/",
                                              headers: [], allowed: [scope], bindings: [])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VECTOR_TESTS"] == "1"))
    func commonPythonAndSwiftVectors() throws {
        let repo = try #require(RepoRoot.resolve(), "Set NVX_REPO to the NVX checkout containing shared vectors")
        let fixture = repo.appendingPathComponent("scripts/testdata/proxy-v1.json")
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        for row in rows {
            let method = try #require(row["method"] as? String), target = try #require(row["target"] as? String)
            let headers = try #require(row["headers"] as? [[String]])
            let pairs = try #require(row["allowed"] as? [[Any]])
            let allowed = Set(try pairs.map { CredentialProxyScope(try #require($0[0] as? String), try #require($0[1] as? Int)) })
            let keys = try #require(row["bindings"] as? [[String: Any]])
            let bindings = try keys.map { item in CredentialProxyBinding(scope: CredentialProxyScope(try #require(item["host"] as? String), try #require(item["port"] as? Int)), value: try #require(item["value"] as? String), header: item["header"] as? String ?? "Authorization", prefix: item["prefix"] as? String ?? "Bearer ", scheme: item["scheme"] as? String ?? "https") }
            if row["error"] as? Bool == true {
                #expect(throws: (any Error).self) { try CredentialProxyPolicy.prepare(method: method, target: target, headers: headers.map { ($0[0], $0[1]) }, allowed: allowed, bindings: bindings) }
            } else {
                let expected = try #require(row["expect"] as? [String: Any])
                let actual = try CredentialProxyPolicy.prepare(method: method, target: target, headers: headers.map { ($0[0], $0[1]) }, allowed: allowed, bindings: bindings)
                #expect(actual.host == expected["host"] as? String)
                #expect(actual.port == expected["port"] as? Int)
                #expect(actual.path == expected["path"] as? String)
                #expect(actual.headers == expected["headers"] as? [String: String])
            }
        }
    }
}
