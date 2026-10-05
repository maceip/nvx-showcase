import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The time machine: browse snapshot generations, inspect the frozen
/// moment, and resume it.
struct SnapshotBrowserView: View {
    @Bindable var store: SnapshotStore
    /// Called when the user sends the selected generation to a Diff tab slot.
    var onSendToDiff: ((URL, ExecDiffStore.DiffSlot) -> Void)? = nil
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Toggle Sidebar", systemImage: "sidebar.left") { store.showsSidebar.toggle() }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Choose…", systemImage: "folder") { showingPicker = true }
                Button("Refresh", systemImage: "arrow.clockwise") { store.rescan() }
                if store.resumeRunning { Button("Stop Restore", systemImage: "stop.fill") { store.stopResume() } }
                Spacer()
                Text(store.rootURL?.path ?? "Choose a snapshot directory")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
            Divider()
            // Safari-style overlay sidebar: the detail page keeps its full
            // width and the Generations panel floats above it on the
            // sidebar material, so collapsing sucks the panel into the
            // leading edge instead of reflowing the page.
            ZStack(alignment: .leading) {
                detail
                if store.showsSidebar {
                    generationsPanel
                        .frame(width: 240)
                        .frame(maxHeight: .infinity)
                        .background(SidebarMaterial())
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(ConsoleStyle.line).frame(width: 1)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 4, y: 0)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.22), value: store.showsSidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsoleStyle.background)
        .foregroundStyle(ConsoleStyle.text)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.rootURL = url
            }
        }
        .onAppear {
            if store.rootURL == nil {
                store.rootURL = URL(fileURLWithPath: "/tmp")
            }
        }
    }
    private var generationsPanel: some View {
        List(selection: $store.selection) {
            Section("Generations") {
                ForEach(store.snapshots) { snap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.url.lastPathComponent).font(.headline)
                        Text("\(InstrumentFormat.compactBytes(snap.totalBytes).value) \(InstrumentFormat.compactBytes(snap.totalBytes).unit)")
                            .font(.caption).foregroundStyle(.secondary)
                        if snap.memorySharesBacking {
                            Text("Sparse or shared RAM")
                                .font(.caption2).foregroundStyle(ConsoleStyle.amber)
                        }
                    }
                    .tag(snap)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.clear)
    }
    private var detail: some View {
        Group {
            if let snap = store.selection {
                SnapshotDetailView(snapshot: snap, store: store, onSendToDiff: onSendToDiff)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 30) {
                        VStack(alignment: .leading, spacing: 12) {
                            InstrumentLabel(text: "Snapshot archive")
                            Text("NO CAPTURES").font(.system(size: 26, weight: .medium, design: .monospaced))
                                .foregroundStyle(ConsoleStyle.muted)
                        }
                        Spacer()
                        MainInstrument(label: "Generations", value: "000")
                    }.padding(20).background(ConsoleStyle.well)
                    ConsoleEmptyState(title: "Archive ready", message: "Choose a snapshot directory, or capture a running guest from the Runtime tab.\nVerified CPU and memory details appear when you inspect a capture.")
                }.padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// Safari's translucent sidebar: an NSVisualEffectView on the .sidebar
/// material that blurs the page content behind the panel.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SnapshotDetailView: View {
    let snapshot: SnapshotInfo
    @Bindable var store: SnapshotStore
    var onSendToDiff: ((URL, ExecDiffStore.DiffSlot) -> Void)? = nil

    private var archiveSize: (value: String, unit: String) { InstrumentFormat.compactBytes(snapshot.totalBytes) }
    private var diskSize: (value: String, unit: String)? { snapshot.allocatedBytes.map(InstrumentFormat.compactBytes) }
    private var memorySize: (value: String, unit: String)? {
        snapshot.files.first(where: { $0.name == "memory.bin" }).map { InstrumentFormat.compactBytes($0.size) }
    }
    private var capturedDate: Date? { snapshot.files.first(where: { $0.name == "manifest.bin" })?.modified }
    private var stateColor: Color {
        store.verifyState == .failed ? ConsoleStyle.red : store.verifyState == .ok ? ConsoleStyle.mint : ConsoleStyle.amber
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 15) {
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 7) {
                            IndicatorLamp(color: stateColor)
                            InstrumentLabel(text: store.resumeRunning ? "Restore in progress" : "Frozen moment")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(store.resumeRunning ? "RESTORING" : store.verifyState == .ok ? "VERIFIED" : store.verifyState == .failed ? "FAILED" : "CAPTURED")
                                .font(.system(size: 25, weight: .medium, design: .monospaced))
                                .tracking(1.5).foregroundStyle(stateColor)
                            if store.verifyState == .ok, !store.contract.tier.isEmpty {
                                Text(store.contract.tier.uppercased())
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .tracking(1.1)
                                    .foregroundStyle(tierColor(store.contract.tier))
                            }
                        }
                        Text(snapshot.url.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(ConsoleStyle.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MainInstrument(label: "Artifacts", value: String(format: "%03d", snapshot.files.count))
                    MainInstrument(label: "Archive size", value: archiveSize.value, unit: archiveSize.unit)
                }
                .padding(18).background(ConsoleStyle.well, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ConsoleStyle.line))
                HStack {
                    InstrumentLabel(text: "Captured resources")
                    Spacer()
                    InstrumentLabel(text: "Snapshot metadata · not live usage")
                }
                HStack(spacing: 8) {
                    ResourceInstrument(label: "CPU", value: store.verifiedCPUCount.map(String.init) ?? "—", unit: "vCPU",
                        detail: store.verifyState == .ok ? "Verified configuration" : "Verify to read configuration")
                    ResourceInstrument(label: "Memory image", value: memorySize?.value ?? "—", unit: memorySize?.unit ?? "",
                        detail: "memory.bin · logical size")
                    ResourceInstrument(label: "Allocated", value: diskSize?.value ?? "—", unit: diskSize?.unit ?? "",
                        detail: snapshot.memorySharesBacking
                            ? "Sparse or shared RAM\nAllocated blocks"
                            : "Allocated blocks\nMay share storage")
                    ResourceInstrument(label: "Architecture", value: store.verifiedArchitecture ?? "—",
                        detail: store.verifyState == .ok ? "Verified manifest" : "Verify to inspect manifest")
                }
                if store.verifyState == .ok {
                    contractStrip
                }
            }
            .padding(16).background(ConsoleStyle.panel)
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    ConsoleSectionHeader(title: "01 / Manifest", trailing: store.verifyState.rawValue)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(ConsoleStyle.muted)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(snapshot.url.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            if let capturedDate {
                                Text("Modified " + capturedDate.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(ConsoleStyle.muted)
                            }
                        }.font(.system(size: 10, design: .monospaced))
                        Spacer(minLength: 0)
                    }.padding(15)
                    if store.verifyOutput.isEmpty {
                        ConsoleEmptyState(title: store.verifyState == .running ? "Inspecting manifest…" : "Awaiting verification",
                            message: "Verify this capture to check its integrity and read the guest configuration.")
                    } else {
                        ScrollView {
                            Text(store.verifyOutput)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(15)
                        }.frame(maxHeight: .infinity)
                    }
                    HStack {
                        Button("Verify", systemImage: "checkmark.shield") { store.verify(snapshot) }
                            .disabled(store.verifyState == .running)
                        if let onSendToDiff {
                            Menu("Send to Diff", systemImage: "arrow.triangle.branch") {
                                Button("As Primary (A)") { onSendToDiff(snapshot.url, .primary) }
                                Button("As Secondary (B)") { onSendToDiff(snapshot.url, .secondary) }
                            }
                            .help("Open a Diff tab comparing this generation")
                        }
                        Spacer()
                        if store.resumeRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Resume this moment", systemImage: "play.fill") { store.resume(snapshot) }
                        }
                    }.padding(12).background(ConsoleStyle.panel)
                }
                .frame(minWidth: 340, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    ConsoleSectionHeader(title: "02 / Artifacts", trailing: "\(snapshot.files.count) files")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(ArtifactSlot.canonical) { slot in
                                artifactRow(slot)
                            }
                            if !extraFiles.isEmpty {
                                InstrumentLabel(text: "Other files")
                                    .padding(.top, 6)
                                ForEach(extraFiles) { file in
                                    HStack {
                                        Text(file.name)
                                            .font(.system(size: 11, design: .monospaced))
                                        Spacer()
                                        Text(byteLabel(file.size))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(ConsoleStyle.mint)
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                    if !store.resumeOutput.isEmpty {
                        ConsoleSectionHeader(title: "Restore output")
                        ScrollView {
                            Text(store.resumeOutput).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }.frame(minHeight: 100)
                    }
                }.frame(minWidth: 260, maxHeight: .infinity)
            }
        }
        .background(ConsoleStyle.background)
    }

    private var extraFiles: [SnapshotFile] {
        snapshot.files.filter { file in
            !ArtifactSlot.canonical.contains { $0.name == file.name }
        }
    }

    private var claimCaption: String {
        if store.contract.resumeClaim == "present" { return "consumed" }
        if store.contract.restorePolicy == "resume" { return "available" }
        return "absent"
    }

    private var contractStrip: some View {
        let contract = store.contract
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 148), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            if !contract.tier.isEmpty {
                ContractBadge(label: "Tier", value: contract.tier, color: tierColor(contract.tier))
            }
            if !contract.restorePolicy.isEmpty {
                ContractBadge(label: "Policy", value: contract.restorePolicy, color: ConsoleStyle.amber)
            }
            if !contract.hypervisor.isEmpty {
                ContractBadge(label: "Hypervisor", value: contract.hypervisor)
            }
            if !contract.bootMode.isEmpty {
                ContractBadge(label: "Boot", value: contract.bootMode)
            }
            if !contract.integrity.isEmpty {
                ContractBadge(label: "Integrity", value: contract.integrity)
            }
            if !contract.scratchPolicy.isEmpty, contract.scratchPolicy != "none" {
                ContractBadge(label: "Scratch", value: contract.scratchPolicy)
            }
            if !contract.resumeClaim.isEmpty {
                ContractBadge(
                    label: "Resume claim",
                    value: claimCaption,
                    color: contract.resumeClaim == "present" ? ConsoleStyle.red : ConsoleStyle.mint
                )
            }
        }
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier {
        case "platform": ConsoleStyle.mint
        case "workload-start": ConsoleStyle.amber
        case "instance-checkpoint": ConsoleStyle.red
        default: ConsoleStyle.muted
        }
    }

    private func byteLabel(_ size: Int64) -> String {
        let formatted = InstrumentFormat.compactBytes(size)
        return "\(formatted.value) \(formatted.unit)"
    }

    private func artifactRow(_ slot: ArtifactSlot) -> some View {
        let file = snapshot.files.first { $0.name == slot.name }
        let present = file != nil
        let lamp = present ? ConsoleStyle.mint : (slot.required ? ConsoleStyle.red : ConsoleStyle.muted)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            IndicatorLamp(color: lamp, lit: present || slot.required)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(slotDetail(slot, file: file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ConsoleStyle.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(file.map { byteLabel($0.size) } ?? "ABSENT")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(present ? ConsoleStyle.mint : ConsoleStyle.muted)
        }
        .padding(10)
        .background(ConsoleStyle.well, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ConsoleStyle.line))
    }

    private func slotDetail(_ slot: ArtifactSlot, file: SnapshotFile?) -> String {
        switch slot.name {
        case "memory.bin":
            if snapshot.memorySharesBacking { return "Guest RAM · sparse or shared backing" }
            return "Guest RAM · logical size only"
        case "scratch.img":
            if store.verifyState == .ok, store.contract.scratchPolicy == "fresh" {
                return "Fresh scratch is supplied at restore"
            }
            if store.verifyState == .ok, store.contract.scratchPolicy == "paired" {
                return "Paired scratch · digest checked"
            }
            return file == nil ? "Not in this generation" : "Writable scratch image"
        case "resume.claim":
            if file != nil { return "Single-use resume consumed" }
            if store.verifyState == .ok, store.contract.restorePolicy == "resume" {
                return "Single-use resume still available"
            }
            return "Not claimed"
        case "state.bin":
            return "Device state · contents stay opaque"
        default:
            return slot.role
        }
    }
}

private struct ArtifactSlot: Identifiable {
    let name: String
    let role: String
    let required: Bool
    var id: String { name }

    static let canonical = [
        ArtifactSlot(name: "manifest.bin", role: "Manifest contract", required: true),
        ArtifactSlot(name: "state.bin", role: "Device state", required: true),
        ArtifactSlot(name: "memory.bin", role: "Guest RAM", required: true),
        ArtifactSlot(name: "scratch.img", role: "Scratch image", required: false),
        ArtifactSlot(name: "resume.claim", role: "Resume claim", required: false),
    ]
}

private struct ContractBadge: View {
    let label: String
    let value: String
    var color: Color = ConsoleStyle.mint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IndicatorLamp(color: color)
                InstrumentLabel(text: label, color: color)
            }
            Text(value.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ConsoleStyle.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsoleStyle.well, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ConsoleStyle.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
