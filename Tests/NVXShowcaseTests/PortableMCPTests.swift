import Foundation
import Testing
@testable import NVXCore

struct PortableMCPTests {
    @Test func languageNeutralProtocolVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/testdata/mcp-v1.json"))
        let vectors = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = try #require(vectors["initialize_response"] as? [String: Any])
        let actual = PortableMCPContract.initialize(id: 1, requestedVersion: "2025-06-18")
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        #expect(PortableMCPContract.toolNames == (vectors["tool_names"] as? [String]))
        let unsupported = try #require(vectors["unsupported_version"] as? String)
        let negotiated = PortableMCPContract.initialize(id: 1, requestedVersion: unsupported)
        let result = try #require(negotiated["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == vectors["negotiated_version"] as? String)
    }
}
