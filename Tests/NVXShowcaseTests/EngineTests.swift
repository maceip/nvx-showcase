import Foundation
import Testing
@testable import NVXCore

@Suite(.serialized)
struct EngineTests {
    @Test func statusReflectsAvailableResources() {
        let status = NVXEngine.shared.checkStatus()
        #expect(status.ready == (status.openvmmExists && status.kernelExists && status.initrdExists))
        #expect(status.defaultSnapshotAvailable == (status.defaultSnapshotPath != nil))
        if status.repoRoot == nil {
            #expect(!status.ready)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VMM_TESTS"] == "1"))
    func statusReportsReady() {
        #expect(NVXEngine.shared.checkStatus().ready)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VMM_TESTS"] == "1"))
    func verifyExistingSnapshot() async throws {
        let engine = NVXEngine.shared
        let snapURL = URL(fileURLWithPath: "/private/tmp/snap-warm-01")
        try #require(FileManager.default.fileExists(atPath: snapURL.appending(path: "manifest.bin").path), "Expected snapshot at /private/tmp/snap-warm-01")
        let manifest = await engine.verifySnapshot(at: snapURL)
        print("Manifest valid:", manifest.isValid, "arch:", manifest.architecture ?? "nil")
        #expect(manifest.isValid == true)
        #expect(manifest.architecture == "aarch64")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VMM_TESTS"] == "1"))
    func runCommandColdBoot() async throws {
        try #require(NVXEngine.shared.checkStatus().ready, "VMM, kernel, and initrd are required")
        let engine = NVXEngine.shared
        let res = try await engine.runCommand(
            command: "echo HELLO_NVX; uname -a",
            timeout: 15.0,
            preferWarmSnapshot: false,
            onOutput: { line in
                print("[VM LINE]:", line)
            }
        )
        print("Cold boot duration: \(res.durationMs)ms, exit: \(res.exitCode)")
        print("Stdout:\n\(res.stdout)")
        #expect(res.exitCode == 0)
        #expect(res.stdout.contains("HELLO_NVX"))
        #expect(res.stdout.contains("Linux"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VMM_TESTS"] == "1"))
    func runCommandWarmSnapshot() async throws {
        try #require(NVXEngine.shared.checkStatus().openvmmExists, "VMM is required")
        let engine = NVXEngine.shared
        let snapURL = URL(fileURLWithPath: "/private/tmp/snap-warm-01")
        try #require(FileManager.default.fileExists(atPath: snapURL.appending(path: "manifest.bin").path), "Expected snapshot at /private/tmp/snap-warm-01")
        let res = try await engine.runCommand(
            command: "echo HELLO_RESTORE; uname -a",
            timeout: 5.0,
            preferWarmSnapshot: true,
            explicitSnapshot: snapURL,
            onOutput: { line in
                print("[RESTORE LINE]:", line)
            }
        )
        print("Warm restore duration: \(res.durationMs)ms, exit: \(res.exitCode)")
        print("Stdout:\n\(res.stdout)")
        #expect(res.exitCode == 0)
        #expect(res.wasRestored == true)
        #expect(res.stdout.contains("HELLO_RESTORE"))
        #expect(res.stdout.contains("Linux"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VMM_TESTS"] == "1"))
    func checkpointLifecycle() throws {
        let engine = NVXEngine.shared
        try #require(engine.checkStatus().defaultSnapshotAvailable, "A source snapshot is required")
        let testCheckpointName = "test-checkpoint-\(UUID().uuidString.prefix(8))"
        defer {
            try? engine.deleteCheckpoint(name: testCheckpointName)
        }
        let url = try engine.createCheckpoint(name: testCheckpointName)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "manifest.bin").path))
        let list = engine.listCheckpoints()
        #expect(list.contains(testCheckpointName))
        try engine.deleteCheckpoint(name: testCheckpointName)
        #expect(!engine.listCheckpoints().contains(testCheckpointName))
    }
}
