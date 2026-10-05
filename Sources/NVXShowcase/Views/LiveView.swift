import SwiftUI
import UniformTypeIdentifiers

/// The glass box: live guest console beside the host denial feed,
/// with the attempted-vs-denied verdict on top.
struct LiveView: View {
    @Bindable var controller: RunController
    /// Called with the save directory's parent when the user reviews a
    /// snapshot captured by the Save sheet.
    var onSnapshotSaved: ((URL) -> Void)? = nil
    @State private var showingSave = false
    @State private var commandInput = "uname -a; uptime"

    private var canLaunch: Bool {
        controller.phase == .idle || controller.phase == .done
    }

    var body: some View {
        VStack(spacing: 0) {
            runControls
            Divider()
            instrumentDeck
            Divider().overlay(ConsoleStyle.line)
            if controller.payload.id == "agent-sandbox" {
                sandboxCommandBar
                Divider()
            }
            HSplitView {
                consolePane
                    .frame(minWidth: 400)
                eventsPane
                    .frame(minWidth: 280, idealWidth: 340)
            }
            if controller.phase == .done, let saved = controller.savedSnapshotURL {
                Divider()
                HStack {
                    Label("Snapshot saved to \(saved.lastPathComponent)",
                          systemImage: "tray.and.arrow.down.fill")
                        .foregroundStyle(ConsoleStyle.muted)
                    Spacer()
                    Button("Review in Snapshots") {
                        onSnapshotSaved?(saved.deletingLastPathComponent())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .background(ConsoleStyle.background)
        .foregroundStyle(ConsoleStyle.text)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showingSave) {
            SaveSnapshotSheet(controller: controller)
        }
    }

    private var runControls: some View {
        HStack(spacing: 12) {
            Group {
                Menu(controller.payload.name) {
                    ForEach(Payload.all) { payload in
                        Button {
                            controller.payload = payload
                        } label: {
                            if controller.payload == payload {
                                Label(payload.name, systemImage: "checkmark")
                            } else {
                                Text(payload.name)
                            }
                        }
                    }
                }
                .help(controller.payload.blurb)
                .disabled(!canLaunch)
            }
            Group {
                Button("Save snapshot…", systemImage: "tray.and.arrow.down") {
                    showingSave = true
                }
                .disabled(!canLaunch)
            }
            Spacer()
            Group {
                if controller.phase == .live {
                    Button("Stop", systemImage: "stop.fill") {
                        controller.stop()
                    }
                } else {
                    Button("Run", systemImage: "play.fill") {
                        controller.launch()
                    }
                    .disabled(controller.phase == .launching)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var sandboxCommandBar: some View {
        HStack(spacing: 12) {
            TextField("Shell command", text: $commandInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(runSandboxCommand)
            Button("Run in Sandbox", action: runSandboxCommand)
        }
        .disabled(!canLaunch)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func runSandboxCommand() {
        guard canLaunch else { return }
        Task { await controller.runAgentCommand(commandInput) }
    }

    private var instrumentDeck: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        IndicatorLamp(color: verdictColor, lit: controller.phase != .idle)
                        InstrumentLabel(text: "Runtime / " + controller.phase.rawValue)
                    }
                    Text(controller.displayStatus)
                        .font(.system(size: 27, weight: .medium, design: .monospaced))
                        .tracking(2).foregroundStyle(verdictColor)
                    Text(controller.payload.blurb)
                        .font(.system(size: 11)).foregroundStyle(ConsoleStyle.muted)
                        .lineLimit(2).frame(maxWidth: 370, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MainInstrument(label: "Attempted", value: String(format: "%03d", controller.attempted))
                MainInstrument(label: "Denied", value: String(format: "%03d", controller.denied))
                TimelineView(.animation(minimumInterval: 1, paused: canLaunch)) { context in
                    MainInstrument(label: "Elapsed", value: InstrumentFormat.elapsed(controller.elapsed(at: context.date)))
                }
                .frame(minWidth: 130, alignment: .leading)
            }
            .padding(18)
            .background(ConsoleStyle.well, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ConsoleStyle.line))

            HStack {
                InstrumentLabel(text: "Resource monitor")
                Spacer()
                InstrumentLabel(text: resourceStatus)
            }
            HStack(spacing: 9) {
                ResourceInstrument(label: "CPU", value: cpuValue, unit: "%",
                    detail: "Host VMM · 100% = one core",
                    fraction: controller.resources.sample?.cpuPercent.map { $0 / 100 })
                ResourceInstrument(label: "Memory", value: InstrumentFormat.mebibytes(controller.resources.sample?.residentBytes),
                    unit: "MiB", detail: "Host VMM · resident memory")
                ResourceInstrument(label: "Disk I/O", value: InstrumentFormat.mebibytes(diskBytes),
                    unit: "MiB", detail: "Host VMM · total read + write")
                ResourceInstrument(label: "Guest allocation", value: controller.allocation.processors.map(String.init) ?? "—",
                    unit: "vCPU", detail: controller.allocation.memoryMiB.map { "\($0) MiB RAM · configured" } ?? "RAM reported after launch")
            }
        }
        .padding(16)
        .background(ConsoleStyle.panel)
    }

    private var cpuValue: String {
        controller.resources.sample?.cpuPercent.map { String(format: "%.1f", $0) } ?? "—"
    }
    private var diskBytes: UInt64? {
        guard let sample = controller.resources.sample, let read = sample.diskReadBytes,
              let written = sample.diskWrittenBytes else { return nil }
        return read + written
    }
    private var resourceStatus: String {
        if controller.phase == .idle { return "Awaiting launch" }
        if controller.resources.sample == nil { return controller.phase == .done ? "No sample collected" : "Waiting for VMM" }
        return controller.phase == .done ? "Last sample · run ended" : "Host readings · 1 sec"
    }
    private var verdictColor: Color {
        if controller.phase == .idle { return ConsoleStyle.muted }
        switch controller.verdict {
        case .contained, .clean: return ConsoleStyle.mint
        case .escaped, .failed: return ConsoleStyle.red
        case .running: return ConsoleStyle.amber
        }
    }

    private var consolePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader(title: "01 / Guest console", trailing: "\(controller.consoleLines.count) lines")
            if controller.consoleLines.isEmpty {
                ConsoleEmptyState(title: "Console ready", message: "Launch a payload to open the guest output stream.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(controller.consoleLines.indices, id: \.self) { index in
                                Text(controller.consoleLines[index])
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).id(index)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(16)
                    }
                    .onChange(of: controller.consoleLines.count) {
                        if let last = controller.consoleLines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsoleStyle.background)
    }

    private var eventsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader(title: "02 / Event feed", trailing: "\(controller.events.count) events")
            if controller.events.isEmpty {
                ConsoleEmptyState(title: "Listening for events", message: "Boot markers, policy denials and snapshot captures appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.events) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: eventIcon(for: event.kind))
                                    .foregroundStyle(eventColor(for: event.kind)).frame(width: 15)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(ConsoleStyle.muted)
                                    Text(StreamParser.displayText(for: event.text))
                                        .font(.system(size: 11)).textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .overlay(alignment: .bottom) { Rectangle().fill(ConsoleStyle.line).frame(height: 1) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsoleStyle.background)
    }

    private func eventIcon(for kind: GuestEvent.Kind) -> String {
        switch kind {
        case .boot: "power"
        case .networkUp: "network"
        case .shareMounted: "folder"
        case .probeSucceeded: "paperplane"
        case .probeFailed: "paperplane.slash"
        case .denied: "nosign"
        case .snapshotSaved: "tray.and.arrow.down.fill"
        case .info: "info.circle"
        }
    }

    private func eventColor(for kind: GuestEvent.Kind) -> Color {
        switch kind {
        case .denied, .probeFailed: ConsoleStyle.red
        case .probeSucceeded, .boot, .snapshotSaved: ConsoleStyle.mint
        default: ConsoleStyle.muted
        }
    }
}

/// Captures a snapshot through the openvmm REPL: boots the payload,
/// waits for a marker, saves, shuts down. The leaf must not exist.
private struct SaveSnapshotSheet: View {
    @Bindable var controller: RunController
    @Environment(\.dismiss) private var dismiss
    @State private var parent: URL = URL(
        fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    @State private var name: String = "nvxsave-" + ISO8601DateFormatter()
        .string(from: Date()).replacingOccurrences(of: ":", with: "-")
    @State private var showingPicker = false
    @State private var errorText = ""
    @State private var timeoutText = "600"

    private var timeoutSeconds: Int {
        max(1, Int(timeoutText) ?? 600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save snapshot")
                .font(.headline)
            Text("Runs \(controller.payload.name) and captures the guest " +
                "once the marker appears.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Directory") {
                HStack {
                    Text(parent.path + "/" + name)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { showingPicker = true }
                }
            }
            LabeledContent("Marker") {
                Text(controller.payload.saveMarker)
                    .font(.callout.monospaced())
            }
            LabeledContent("Timeout (s)") {
                TextField("600", text: $timeoutText)
                    .frame(width: 80)
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let dir = parent.appending(path: name,
                                               directoryHint: .isDirectory)
                    if controller.launchSaving(
                        to: dir,
                        marker: controller.payload.saveMarker,
                        timeoutSeconds: timeoutSeconds)
                    {
                        dismiss()
                    } else {
                        errorText = "That directory already exists; " +
                            "pick a new name (snap refuses an existing leaf)."
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.phase != .idle &&
                    controller.phase != .done)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                parent = url
            }
        }
    }
}
