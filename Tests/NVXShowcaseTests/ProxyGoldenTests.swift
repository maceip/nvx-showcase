import Foundation
import Testing
@testable import NVXCore

struct ProxyGoldenTests {
    @Test func commonPythonAndSwiftVectors() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/testdata/proxy-v1.json")
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
