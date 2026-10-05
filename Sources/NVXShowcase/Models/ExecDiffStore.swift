import Foundation
import NVXCore

struct ExecModule: Identifiable, Decodable, Hashable {
    let digest: String
    let execBytes: Int
    let status: String
    let similarity: Double
    let name: String
    let entry: Int
    let primaryGpa: Int?
    let secondaryGpa: Int?
    var id: String { digest }
    var gpa: Int? { secondaryGpa ?? primaryGpa }
    var side: String { secondaryGpa != nil ? "secondary" : "primary" }
}

struct ExecFunction: Identifiable, Decodable, Hashable {
    let address: Int
    let size: Int
    let name: String
    var id: Int { address }
}

struct ExecInstruction: Decodable, Hashable {
    let address: Int
    let mnemonic: String
    let op: String
}

struct ExecBlock: Identifiable, Decodable, Hashable {
    let address: Int
    let successors: [Int]
    let instructions: [ExecInstruction]
    var id: Int { address }
}

struct ExecCall: Identifiable, Decodable, Hashable {
    let address: Int
    let name: String
    var id: Int { address }
}

struct ExecGraph: Decodable {
    let address: Int
    let name: String
    let blocks: [ExecBlock]
    let calls: [ExecCall]
}

private struct ModuleReport: Decodable {
    let modules: [ExecModule]
}

private struct FunctionReport: Decodable {
    let entry: Int
    let functions: [ExecFunction]
}

/// Compares executable images in two snapshot memory files and loads one
/// function's call neighborhood and basic-block graph.
@Observable
@MainActor
final class ExecDiffStore {
    var primaryURL: URL?
    var secondaryURL: URL?
    var modules: [ExecModule] = []
    var selection: ExecModule?
    var functions: [ExecFunction] = []
    var functionSelection: ExecFunction?
    var graph: ExecGraph?
    var status = "Choose two snapshots"
    var running = false
    var functionFilter = ""
    /// Entry address from the last function report, used for the ENTRY badge.
    var entryAddress: Int?
    private var task = UUID()

    /// Which snapshot slot a URL fills when sent from the Snapshots page.
    enum DiffSlot {
        case primary
        case secondary
    }

    var identicalCount: Int { modules.filter { $0.status == "identical" }.count }
    var primaryOnly: Int { modules.filter { $0.status == "primary" }.count }
    var secondaryOnly: Int { modules.filter { $0.status == "secondary" }.count }
    var visibleFunctions: [ExecFunction] {
        let query = functionFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return functions }
        return functions.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || String(format: "%x", $0.address).localizedCaseInsensitiveContains(query)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "execDiffPrimary") {
            primaryURL = URL(fileURLWithPath: path)
        }
        if let path = defaults.string(forKey: "execDiffSecondary") {
            secondaryURL = URL(fileURLWithPath: path)
        }
        if primaryURL == nil || secondaryURL == nil, let repo = RepoRoot.resolve() {
            let proof = repo.appending(path: "build/snapshot-proof")
            let boot = proof.appending(path: "generation")
            let node = proof.appending(path: "node-app")
            if primaryURL == nil, Self.hasMemory(boot) { primaryURL = boot }
            if secondaryURL == nil, Self.hasMemory(node) { secondaryURL = node }
        }
    }

    func remember() {
        if let primaryURL {
            UserDefaults.standard.set(primaryURL.path, forKey: "execDiffPrimary")
        }
        if let secondaryURL {
            UserDefaults.standard.set(secondaryURL.path, forKey: "execDiffSecondary")
        }
    }

    /// Fill one or both snapshot slots, e.g. from the Snapshots page's
    /// "Send to Diff" action. Persists the choice; callers trigger compare().
    func setSnapshots(primary: URL?, secondary: URL?) {
        if let primary { primaryURL = primary }
        if let secondary { secondaryURL = secondary }
        remember()
    }

    func setSlot(_ url: URL, _ slot: DiffSlot) {
        switch slot {
        case .primary: primaryURL = url
        case .secondary: secondaryURL = url
        }
        remember()
    }

    /// Exchange the two snapshot slots.
    func swap() {
        (primaryURL, secondaryURL) = (secondaryURL, primaryURL)
        remember()
    }

    /// Which side's bytes the graph panes render, derived from the
    /// selected module: identical matches prefer the secondary image.
    var graphedSide: String {
        guard let selection else { return "—" }
        return selection.secondaryGpa != nil ? "Secondary image" : "Primary image"
    }

    /// True when both slots point at snapshot generations (manifest present).
    var slotsReady: Bool {
        guard let primaryURL, let secondaryURL else { return false }
        return Self.isGeneration(primaryURL) && Self.isGeneration(secondaryURL)
    }

    func compare() {
        guard let primaryURL, let secondaryURL else {
            status = "Choose a primary and a secondary snapshot"
            return
        }
        guard let repo = RepoRoot.resolve() else {
            status = "No nvx checkout found"
            return
        }
        running = true
        status = "Comparing executable images"
        selection = nil
        functions = []
        functionSelection = nil
        entryAddress = nil
        graph = nil
        let generation = UUID()
        task = generation
        let primary = primaryURL.path
        let secondary = secondaryURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (stdout, stderr, ok) = Self.run(
                repo: repo,
                args: ["execdiff", "modules", primary, secondary]
            )
            Task { @MainActor [weak self] in
                guard let self, self.task == generation else { return }
                self.running = false
                guard ok, let report = Self.decode(ModuleReport.self, from: stdout) else {
                    self.modules = []
                    self.status = stderr.isEmpty ? "Compare failed" : stderr
                    return
                }
                self.modules = report.modules
                self.selection = report.modules.first
                self.status = "\(report.modules.count) executable images"
                if let selected = self.selection { self.loadFunctions(selected) }
            }
        }
    }

    func loadFunctions(_ module: ExecModule) {
        selection = module
        functions = []
        functionSelection = nil
        entryAddress = nil
        graph = nil
        guard let gpa = module.gpa, let snapshot = snapshotURL(for: module) else { return }
        guard let repo = RepoRoot.resolve() else { return }
        running = true
        let generation = UUID()
        task = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (stdout, stderr, ok) = Self.run(
                repo: repo,
                args: ["execdiff", "functions", snapshot.path, "--gpa", String(gpa)]
            )
            Task { @MainActor [weak self] in
                guard let self, self.task == generation else { return }
                self.running = false
                guard ok, let report = Self.decode(FunctionReport.self, from: stdout) else {
                    self.status = stderr.isEmpty ? "Function list failed" : stderr
                    return
                }
                self.functions = report.functions
                self.entryAddress = report.entry
                self.functionSelection = report.functions.first { $0.address == report.entry }
                    ?? report.functions.first
                if let function = self.functionSelection {
                    self.loadGraph(module, function)
                }
            }
        }
    }

    func loadGraph(_ module: ExecModule, _ function: ExecFunction) {
        functionSelection = function
        graph = nil
        guard let gpa = module.gpa, let snapshot = snapshotURL(for: module) else { return }
        guard let repo = RepoRoot.resolve() else { return }
        running = true
        let generation = UUID()
        task = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (stdout, stderr, ok) = Self.run(
                repo: repo,
                args: [
                    "execdiff", "graph", snapshot.path,
                    "--gpa", String(gpa),
                    "--address", String(function.address),
                ]
            )
            Task { @MainActor [weak self] in
                guard let self, self.task == generation else { return }
                self.running = false
                guard ok, let report = Self.decode(ExecGraph.self, from: stdout) else {
                    self.status = stderr.isEmpty ? "Graph failed" : stderr
                    return
                }
                self.graph = report
                self.status = module.status == "identical"
                    ? "Executable bytes match"
                    : "Unmatched executable image"
            }
        }
    }

    func stop() {
        task = UUID()
        running = false
    }

    private func snapshotURL(for module: ExecModule) -> URL? {
        if module.secondaryGpa != nil { return secondaryURL }
        return primaryURL
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: Data(text.utf8))
    }

    nonisolated private static func hasMemory(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "memory.bin").path)
    }

    nonisolated private static func isGeneration(_ directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appending(path: "manifest.bin").path)
            && fm.fileExists(atPath: directory.appending(path: "memory.bin").path)
    }

    nonisolated private static func run(repo: URL, args: [String]) -> (String, String, Bool) {
        let proc = Process()
        proc.executableURL = RepoRoot.python3(near: repo)
        proc.arguments = [repo.appending(path: "scripts/nvx.py").path] + args
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.currentDirectoryURL = repo
        do { try proc.run() } catch {
            return ("", "failed to launch nvx.py: \(error)", false)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        return (stdout, stderr, proc.terminationStatus == 0)
    }
}
