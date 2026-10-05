import Foundation
import NVXCore

/// One artifact file inside a snapshot generation.
struct SnapshotFile: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let size: Int64
    let modified: Date
    var allocatedSize: Int64? = nil
}

/// Fields printed by `nvx.py snapshot verify`. Empty strings mean the
/// generation did not declare that fact. Guest RAM bytes are never here.
struct SnapshotContract: Equatable {
    var tier = ""
    var restorePolicy = ""
    var hypervisor = ""
    var bootMode = ""
    var integrity = ""
    var scratchPolicy = ""
    var resumeClaim = ""
    var consumedSections = ""

    static func parse(_ output: String) -> SnapshotContract {
        func value(_ prefix: String) -> String {
            for line in output.components(separatedBy: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix(prefix) else { continue }
                return text.dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespaces)
            }
            return ""
        }
        func shown(_ raw: String) -> String {
            raw == "(none)" ? "" : raw
        }
        return SnapshotContract(
            tier: shown(value("snapshot tier:")),
            restorePolicy: shown(value("restore policy:")),
            hypervisor: shown(value("source hypervisor:")),
            bootMode: value("boot mode:"),
            integrity: value("payload integrity:"),
            scratchPolicy: value("scratch policy:"),
            resumeClaim: value("resume claim:"),
            consumedSections: shown(value("consumed sections:"))
        )
    }
}

/// One snapshot generation directory on disk. Identity is the directory
/// so selection survives rescans (a fresh UUID per scan would force a
/// full row reload and drop selection).
struct SnapshotInfo: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let files: [SnapshotFile]

    /// Guest RAM whose allocated blocks are far below the logical image.
    /// That is a sparse file or an APFS clone, not a measurement of sharing.
    var memorySharesBacking: Bool {
        guard let memory = files.first(where: { $0.name == "memory.bin" }),
              let allocated = memory.allocatedSize,
              memory.size >= 1024 * 1024 else { return false }
        return allocated * 2 < memory.size
    }

    var totalBytes: Int64 { files.map(\.size).reduce(0, +) }
    var allocatedBytes: Int64? {
        guard files.allSatisfy({ $0.allocatedSize != nil }) else { return nil }
        return files.compactMap(\.allocatedSize).reduce(0, +)
    }

    static func == (lhs: SnapshotInfo, rhs: SnapshotInfo) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

/// Scans a root for snapshot generations (directories with manifest.bin),
/// verifies them through `nvx.py snapshot verify`, and runs restores.
@Observable
@MainActor
final class SnapshotStore {
    var rootURL: URL? {
        didSet {
            if let rootURL {
                UserDefaults.standard.set(rootURL.path, forKey: "snapshotRoot")
            }
            rescan()
        }
    }
    var snapshots: [SnapshotInfo] = []
    var selection: SnapshotInfo? {
        didSet {
            guard oldValue?.id != selection?.id else { return }
            verificationGeneration = UUID()
            verifyOutput = ""
            verifyState = .idle
            if !resumeRunning { resumeOutput = "" }
        }
    }
    var verifyOutput: String = ""
    var verifyState: VerifyState = .idle
    var resumeOutput: String = ""
    var resumeRunning = false
    var showsSidebar = true
    private var resumeProcess: Process?
    private var resumeGeneration = UUID()
    private var verificationGeneration = UUID()

    var verifiedCPUCount: Int? {
        guard let value = verifiedField("vCPUs:"), let count = Int(value), count > 0 else { return nil }
        return count
    }
    var verifiedArchitecture: String? { verifiedField("architecture:") }
    var contract: SnapshotContract {
        guard verifyState == .ok else { return SnapshotContract() }
        return SnapshotContract.parse(verifyOutput)
    }
    private func verifiedField(_ prefix: String) -> String? {
        guard verifyState == .ok else { return nil }
        return verifyOutput.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(prefix) else { return nil }
            let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }.first
    }

    enum VerifyState: String {
        case idle = "Not verified"
        case running = "Verifying…"
        case ok = "Verified"
        case failed = "Failed"
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: "snapshotRoot") {
            rootURL = URL(fileURLWithPath: path)
            rescan()
        }
    }

    /// Directory enumeration runs off the main thread; a busy root
    /// (e.g. /tmp with thousands of entries) must not hitch the UI.
    /// Selection is preserved by directory across rescans.
    func rescan() {
        guard let rootURL else {
            snapshots = []
            selection = nil
            return
        }
        let previousSelection = selection?.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.scan(root: rootURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshots = found
                if let prev = previousSelection,
                   let match = found.first(where: { $0.url == prev }) {
                    self.selection = match
                } else {
                    self.selection = found.first
                }
            }
        }
    }

    nonisolated private static func scan(root: URL) -> [SnapshotInfo] {
        let fm = FileManager.default
        // Resolve first: isDirectoryKey reports false for symlink roots
        // such as /tmp -> /private/tmp, which would skip enumeration.
        let resolved = root.resolvingSymlinksInPath()
        var candidates = [resolved]
        if let children = try? fm.contentsOfDirectory(at: resolved,
                                                      includingPropertiesForKeys: [.isDirectoryKey]) {
            candidates += children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }
        // Only directories containing a manifest are generations; filter
        // before capping so a busy root (e.g. /tmp) still yields results.
        let generationDirs = candidates.filter { dir in
            (try? dir.appending(path: "manifest.bin").checkResourceIsReachable()) == true
        }.prefix(256)
        var infos: [SnapshotInfo] = []
        for dir in generationDirs {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
                .compactMap { url -> SnapshotFile? in
                    guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]),
                          vals.isDirectory != true else { return nil }
                    return SnapshotFile(name: url.lastPathComponent,
                                        size: Int64(vals.fileSize ?? 0),
                                        modified: vals.contentModificationDate ?? .distantPast,
                                        allocatedSize: vals.totalFileAllocatedSize.map(Int64.init))
                }
                .sorted { $0.name < $1.name }
            infos.append(SnapshotInfo(url: dir, files: files))
        }
        infos.sort { $0.url.path < $1.url.path }
        return infos
    }

    func verify(_ snapshot: SnapshotInfo) {
        guard let repo = RepoRoot.resolve() else {
            verifyOutput = "verify failed: no nvx checkout found " +
                "(set NVX_REPO or the repoRoot default)"
            verifyState = .failed
            return
        }
        verifyState = .running
        verifyOutput = ""
        let generation = UUID()
        verificationGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (text, ok) = Self.runNVX(repo: repo,
                                         args: ["snapshot", "verify",
                                                snapshot.url.path])
            Task { @MainActor [weak self] in
                guard let self, self.verificationGeneration == generation else { return }
                self.verifyOutput = text
                self.verifyState = ok ? .ok : .failed
            }
        }
    }

    /// Runs `nvx.py` with piped output on a background queue.
    /// Returns (combined output, exited zero).
    nonisolated private static func runNVX(repo: URL,
                                           args: [String]) -> (String, Bool) {
        let proc = Process()
        proc.executableURL = RepoRoot.python3(near: repo)
        proc.arguments = [repo.appending(path: "scripts/nvx.py").path] + args
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.currentDirectoryURL = repo
        do {
            try proc.run()
        } catch {
            return ("failed to launch nvx.py: \(error)", false)
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        proc.waitUntilExit()
        return (text, proc.terminationStatus == 0)
    }

    /// Guest arch recorded by the last verify run, e.g. "aarch64".
    private var verifiedArch: String? {
        for line in verifyOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("architecture:") {
                return trimmed.dropFirst("architecture:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func resume(_ snapshot: SnapshotInfo) {
        guard !resumeRunning else { return }
        guard let repo = RepoRoot.resolve() else {
            resumeOutput = "resume failed: no nvx checkout found " +
                "(set NVX_REPO or the repoRoot default)"
            return
        }
        // An x86_64 guest cannot boot under HVF on Apple Silicon; refuse
        // early instead of launching a doomed restore.
        if let arch = verifiedArch, arch != "aarch64" {
            resumeOutput = "resume refused: snapshot architecture is " +
                "\(arch); this Mac can only restore aarch64 under HVF."
            return
        }
        resumeRunning = true
        resumeOutput = ""
        let proc = Process()
        proc.executableURL = RepoRoot.python3(near: repo)
        proc.arguments = [repo.appending(path: "scripts/nvx.py").path,
                          "run", "--hypervisor", "hvf",
                          "--restore-snapshot", snapshot.url.path]
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.currentDirectoryURL = repo
        do {
            try proc.run()
        } catch {
            resumeOutput = "resume failed to launch: \(error)"
            resumeRunning = false
            return
        }
        resumeProcess = proc
        let generation = UUID()
        resumeGeneration = generation
        // If the shim exits while openvmm lingers, the VM would orphan;
        // sweep the tree on the way out. (A restore boot that stays up
        // keeps running until the next resume/stop kills it.)
        DispatchQueue.global().async { [weak self] in
            // Drain while the process runs; waiting first can fill the pipe
            // and deadlock a verbose restored guest in an inactive tab.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                RepoRoot.killProcessTree(proc, graceSeconds: 0)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self, self.resumeGeneration == generation else { return }
                self.resumeOutput = text
                self.resumeRunning = false
                self.resumeProcess = nil
            }
        }
    }

    func stopResume() {
        resumeGeneration = UUID()
        if let resumeProcess { RepoRoot.killProcessTree(resumeProcess) }
        resumeProcess = nil
        resumeRunning = false
    }
}
