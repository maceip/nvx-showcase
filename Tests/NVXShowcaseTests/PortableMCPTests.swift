import Foundation
import Testing
@testable import NVXCore

struct PortableMCPTests {
    @Test func standaloneInitializeContract() throws {
        let response = PortableMCPContract.initialize(id: 7, requestedVersion: "unsupported")
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? Int == 7)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let server = try #require(result["serverInfo"] as? [String: Any])
        #expect(server["name"] as? String == "nvx")
        #expect(PortableMCPContract.toolNames.contains("nvx_run"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VECTOR_TESTS"] == "1"))
    func languageNeutralProtocolVectors() throws {
        let repo = try #require(RepoRoot.resolve(), "Set NVX_REPO to the NVX checkout containing shared vectors")
        let data = try Data(contentsOf: repo.appendingPathComponent("scripts/testdata/mcp-v1.json"))
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
