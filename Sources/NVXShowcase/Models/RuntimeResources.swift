import Foundation
import Darwin

/// Host measurements of the VMM, not guest Linux utilization or disk capacity.
struct RuntimeResourceSample: Sendable {
    let date: Date
    let cpuPercent: Double?
    let residentBytes: UInt64
    let diskReadBytes: UInt64?
    let diskWrittenBytes: UInt64?
}

struct GuestAllocation: Equatable {
    var processors: Int?
    var memoryMiB: Int?

    /// nvx.py prints the resolved OpenVMM invocation; read its values rather
    /// than duplicating CLI defaults, which can change independently of this app.
    mutating func ingest(command: String) {
        guard command.hasPrefix(">> "), command.contains("openvmm") else { return }
        func number(_ pattern: String) -> Int? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  let range = Range(match.range(at: 1), in: command) else { return nil }
            return Int(command[range])
        }
        processors = number(#"--processors\s+(\d+)(?:\s|$)"#) ?? processors
        memoryMiB = number(#"--memory\s+(\d+)M(?:\s|$)"#) ?? memoryMiB
    }
}

/// One low-frequency sampler per active tab. Discovery and libproc calls run
/// off the UI thread; the timer is released when the owned run ends.
@MainActor @Observable
final class RuntimeResourceMonitor {
    private(set) var sample: RuntimeResourceSample?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(rootPID: Int32, directVMM: Bool = false) {
        stop(clear: true)
        let generation = generation
        task = Task { [weak self] in
            let reader = VMMResourceReader(rootPID: rootPID, directVMM: directVMM)
            while !Task.isCancelled {
                let next = await reader.read()
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                if let next { self.sample = next }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop(clear: Bool = false) {
        generation = UUID()
        task?.cancel()
        task = nil
        if clear { sample = nil }
    }
}

private actor VMMResourceReader {
    let rootPID: Int32
    var vmmPID: Int32?
    var previous: (cpu: UInt64, time: TimeInterval)?
    init(rootPID: Int32, directVMM: Bool) {
        self.rootPID = rootPID
        self.vmmPID = directVMM ? rootPID : nil
    }

    func read() -> RuntimeResourceSample? {
        if vmmPID == nil { vmmPID = findVMM() }
        guard let pid = vmmPID else { return nil }
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let total = info.pti_total_user + info.pti_total_system
        var cpu: Double?
        if let previous, now > previous.time, total >= previous.cpu {
            // proc_taskinfo total times are nanoseconds; 100% means one host core.
            cpu = Double(total - previous.cpu) / 1_000_000_000 / (now - previous.time) * 100
        }
        previous = (total, now)
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return RuntimeResourceSample(date: Date(), cpuPercent: cpu, residentBytes: info.pti_resident_size,
            diskReadBytes: result == 0 ? usage.ri_diskio_bytesread : nil,
            diskWrittenBytes: result == 0 ? usage.ri_diskio_byteswritten : nil)
    }

    private func findVMM() -> Int32? {
        // Inspect names/PIDs only, never arbitrary process arguments or secrets.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rows = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line -> (Int32, Int32, String)? in
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return (pid, parent, String(parts[2]))
        }
        var descendants: Set<Int32> = [rootPID]
        for _ in 0..<8 {
            let children = rows.filter { descendants.contains($0.1) }.map(\.0)
            let before = descendants.count
            descendants.formUnion(children)
            if descendants.count == before { break }
        }
        return rows.first { descendants.contains($0.0) && URL(fileURLWithPath: $0.2).lastPathComponent == "openvmm" }?.0
    }
}

enum InstrumentFormat {
    static func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        if value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    static func mebibytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.1f", Double(bytes) / 1_048_576)
    }
    static func compactBytes(_ bytes: Int64) -> (value: String, unit: String) {
        let value = Double(max(0, bytes))
        if value >= 1_073_741_824 { return (String(format: "%.2f", value / 1_073_741_824), "GiB") }
        if value >= 1_048_576 { return (String(format: "%.1f", value / 1_048_576), "MiB") }
        if value >= 1024 { return (String(format: "%.1f", value / 1024), "KiB") }
        return (String(max(0, bytes)), "B")
    }
}
