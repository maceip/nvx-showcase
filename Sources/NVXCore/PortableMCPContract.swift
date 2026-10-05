import Foundation

/// The portable CLI contract; independent of the optional macOS app's tools.
public enum PortableMCPContract {
    public static let protocolVersion = "2025-06-18"
    public static let toolNames = ["nvx_run", "nvx_exec", "nvx_status", "nvx_snapshot", "nvx_files", "nvx_secrets"]
    public static func initialize(id: Int, requestedVersion: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "nvx", "version": "1.0"]
        ]]
    }
}
