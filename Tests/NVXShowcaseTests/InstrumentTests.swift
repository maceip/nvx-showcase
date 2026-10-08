import Foundation
import Testing
@testable import NVXCore
@testable import NVXShowcase

@Suite(.serialized) @MainActor
struct InstrumentTests {
    @Test func allocationUsesResolvedInvocationNotGuestLogText() {
        var allocation = GuestAllocation()
        allocation.ingest(command: "guest printed --processors 99 --memory 12M")
        #expect(allocation.processors == nil && allocation.memoryMiB == nil)
        allocation.ingest(command: ">> /repo/openvmm --single-process --processors 2 --memory 2048M --memory-backing-file /tmp/mem")
        #expect(allocation == GuestAllocation(processors: 2, memoryMiB: 2048))
        var restore = GuestAllocation()
        restore.ingest(command: ">> /repo/openvmm --processors 1 --restore-snapshot /tmp/snap")
        #expect(restore.processors == 1 && restore.memoryMiB == nil)
    }

    @Test func unavailableAndTimeFormattingDoNotInventValues() {
        #expect(InstrumentFormat.mebibytes(nil) == "—")
        #expect(InstrumentFormat.mebibytes(0) == "0.0")
        #expect(InstrumentFormat.elapsed(59) == "00:59")
        #expect(InstrumentFormat.elapsed(3601) == "01:00:01")
        #expect(InstrumentFormat.compactBytes(2_147_483_648).value == "2.00")
        let controller = RunController()
        #expect(controller.displayStatus == "STANDBY")
        #expect(controller.elapsed(at: .now) == 0)
    }

    @Test func snapshotContractParsesVerifyReportAndStaysHiddenUntilSuccess() {
        let text = """
          snapshot tier: workload-start
          restore policy: clone
          source hypervisor: hvf
          boot mode: linux-direct
          payload integrity: SHA-256 verified
          scratch policy: paired
          resume claim: absent
          consumed sections: invariants,image-binding,sandbox
          architecture: aarch64
          vCPUs: 1
        """
        let parsed = SnapshotContract.parse(text)
        #expect(parsed.tier == "workload-start")
        #expect(parsed.restorePolicy == "clone")
        #expect(parsed.hypervisor == "hvf")
        #expect(parsed.bootMode == "linux-direct")
        #expect(parsed.integrity == "SHA-256 verified")
        #expect(parsed.scratchPolicy == "paired")
        #expect(parsed.resumeClaim == "absent")
        let store = SnapshotStore()
        store.verifyOutput = text
        store.verifyState = .failed
        #expect(store.contract == SnapshotContract())
        store.verifyState = .ok
        #expect(store.contract.tier == "workload-start")
        #expect(store.contract.hypervisor == "hvf")
        #expect(store.verifiedCPUCount == 1)
    }

    @Test func sparseMemoryFlagsSharedBackingOnlyForLargeImages() {
        let dense = SnapshotInfo(
            url: URL(fileURLWithPath: "/tmp/dense"),
            files: [SnapshotFile(name: "memory.bin", size: 2_000_000, modified: .now, allocatedSize: 2_000_000)]
        )
        #expect(!dense.memorySharesBacking)
        let tiny = SnapshotInfo(
            url: URL(fileURLWithPath: "/tmp/tiny"),
            files: [SnapshotFile(name: "memory.bin", size: 4096, modified: .now, allocatedSize: 0)]
        )
        #expect(!tiny.memorySharesBacking)
        let sparse = SnapshotInfo(
            url: URL(fileURLWithPath: "/tmp/sparse"),
            files: [SnapshotFile(name: "memory.bin", size: 8_000_000, modified: .now, allocatedSize: 4096)]
        )
        #expect(sparse.memorySharesBacking)
    }

    @Test func snapshotConfigurationRequiresSuccessfulVerificationAndResetsOnSelection() {
        let store = SnapshotStore()
        store.verifyOutput = "  architecture: aarch64\n  vCPUs: 2\n"
        store.verifyState = .failed
        #expect(store.verifiedCPUCount == nil && store.verifiedArchitecture == nil)
        store.verifyState = .ok
        #expect(store.verifiedCPUCount == 2 && store.verifiedArchitecture == "aarch64")
        store.selection = SnapshotInfo(url: URL(fileURLWithPath: "/tmp/another-generation"), files: [])
        #expect(store.verifiedCPUCount == nil && store.verifyState == .idle)
    }

    @Test func silentProcessExitFreezesElapsedAndStopsSampling() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nvx-quiet-exit-\(UUID())")
        let scripts = root.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "import time\ntime.sleep(0.1)\n".write(to: scripts.appending(path: "nvx.py"), atomically: true, encoding: .utf8)
        let controller = RunController(runsRoot: root.appending(path: "runs"), resolveRepository: { root })
        defer { controller.stop(); try? FileManager.default.removeItem(at: root) }
        controller.launch()
        for _ in 0..<30 where controller.phase != .done { try await Task.sleep(for: .milliseconds(100)) }
        #expect(controller.phase == .done)
        #expect(controller.endedAt != nil)
        #expect(controller.elapsed(at: .now) == controller.elapsed(at: Date().addingTimeInterval(100)))
    }

    @Test func samplerReadsRealProcessAndRetainsFinalSampleAfterStop() async throws {
        let monitor = RuntimeResourceMonitor()
        // Exercise libproc using this test process; no synthetic utilization values.
        monitor.start(rootPID: getpid(), directVMM: true)
        defer { monitor.stop() }
        for _ in 0..<30 where monitor.sample?.cpuPercent == nil { try await Task.sleep(for: .milliseconds(100)) }
        let sample = try #require(monitor.sample)
        #expect(sample.residentBytes > 0)
        #expect(sample.cpuPercent != nil)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.sample?.date == sample.date)
        monitor.stop(clear: true)
        #expect(monitor.sample == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NVX_VMM_TESTS"] == "1"))
    func agentCommandCollectsActualVMMResources() async throws {
        try #require(NVXEngine.shared.checkStatus().ready, "VMM, kernel, and initrd are required")
        let controller = RunController()
        controller.payload = .agentSandbox
        await controller.runAgentCommand("sleep 2; echo NVX_METRICS_CHECK", preferWarmSnapshot: false)
        #expect(controller.phase == .done)
        #expect(controller.consoleLines.contains { $0.contains("NVX_METRICS_CHECK") })
        #expect(controller.allocation.processors == 1)
        #expect(controller.allocation.memoryMiB == 512)
        let sample = try #require(controller.resources.sample)
        #expect(sample.residentBytes > 0 && sample.cpuPercent != nil)
        #expect(sample.diskReadBytes != nil && sample.diskWrittenBytes != nil)
        #expect(controller.elapsed(at: .now) >= 2)
        print("VMM measured: CPU \(sample.cpuPercent ?? -1)%, RSS \(sample.residentBytes) bytes, disk read \(sample.diskReadBytes ?? 0) bytes")
    }
}
