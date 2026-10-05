import Foundation
import Testing
@testable import NVXShowcase

@Suite(.serialized) @MainActor
struct ExecDiffStoreTests {
    @Test func snapshotSlotsFillSwapAndReportSide() {
        UserDefaults.standard.removeObject(forKey: "execDiffPrimary")
        UserDefaults.standard.removeObject(forKey: "execDiffSecondary")
        let store = ExecDiffStore()
        defer {
            store.stop()
            UserDefaults.standard.removeObject(forKey: "execDiffPrimary")
            UserDefaults.standard.removeObject(forKey: "execDiffSecondary")
        }
        let primary = URL(fileURLWithPath: "/tmp/diff-primary")
        let secondary = URL(fileURLWithPath: "/tmp/diff-secondary")
        // Only the supplied slot is overwritten.
        store.setSnapshots(primary: primary, secondary: nil)
        #expect(store.primaryURL == primary)
        store.setSlot(secondary, .secondary)
        #expect(store.secondaryURL == secondary)
        store.setSnapshots(primary: nil, secondary: primary)
        #expect(store.primaryURL == primary)
        #expect(store.secondaryURL == primary)
        store.setSnapshots(primary: primary, secondary: secondary)
        store.swap()
        #expect(store.primaryURL == secondary)
        #expect(store.secondaryURL == primary)
        // No selection means no graphed side.
        #expect(store.graphedSide == "—")
    }

    @Test func functionFilterMatchesNameAndAddress() {
        let store = ExecDiffStore()
        defer { store.stop() }
        store.functions = [
            ExecFunction(address: 0x1000, size: 32, name: "main"),
            ExecFunction(address: 0x2000, size: 64, name: "helper_parse"),
        ]
        store.functionFilter = ""
        #expect(store.visibleFunctions.count == 2)
        store.functionFilter = "parse"
        #expect(store.visibleFunctions.map(\.name) == ["helper_parse"])
        store.functionFilter = "2000"
        #expect(store.visibleFunctions.map(\.name) == ["helper_parse"])
        store.functionFilter = "  "
        #expect(store.visibleFunctions.count == 2)
    }

    @Test func workspaceSendToDiffKeepsExistingSlot() {
        UserDefaults.standard.removeObject(forKey: "execDiffPrimary")
        UserDefaults.standard.removeObject(forKey: "execDiffSecondary")
        let workspace = ShowcaseWorkspace()
        defer {
            workspace.stopAll()
            UserDefaults.standard.removeObject(forKey: "execDiffPrimary")
            UserDefaults.standard.removeObject(forKey: "execDiffSecondary")
        }
        let first = URL(fileURLWithPath: "/tmp/diff-a")
        let second = URL(fileURLWithPath: "/tmp/diff-b")
        // Init may prefill slots from the checkout's snapshot-proof
        // fixtures; clear them so single-slot behavior is observable.
        for tab in workspace.tabs where tab.kind == .diff {
            tab.diff.primaryURL = nil
            tab.diff.secondaryURL = nil
        }
        // Single-slot sends must not clear the other slot, and must land
        // on a Diff tab without starting a compare on a missing side.
        workspace.openDiffComparing(primary: first, secondary: nil)
        guard let diff = workspace.tabs.first(where: { $0.kind == .diff }) else {
            Issue.record("expected a diff tab")
            return
        }
        #expect(diff.diff.primaryURL == first)
        #expect(diff.diff.secondaryURL == nil)
        #expect(workspace.selectedID == diff.id)
        workspace.openDiffComparing(primary: nil, secondary: second)
        #expect(diff.diff.primaryURL == first)
        #expect(diff.diff.secondaryURL == second)
    }
}
