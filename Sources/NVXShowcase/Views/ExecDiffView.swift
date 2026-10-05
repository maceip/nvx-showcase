import SwiftUI
import UniformTypeIdentifiers

/// Executable-image diff: module match list, call neighborhood, and the
/// basic-block graph of the selected function. Only executable segments
/// are shown.
struct ExecDiffView: View {
    @Bindable var store: ExecDiffStore
    @State private var pickingPrimary = false
    @State private var pickingSecondary = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            instruments
            Divider().overlay(ConsoleStyle.line)
            if store.modules.isEmpty {
                ConsoleEmptyState(
                    title: store.running ? "Reading executable segments…" : "No comparison yet",
                    message: "Choose two snapshot directories. The view matches AArch64 executable images by the hash of their executable bytes, then opens one function's calls and basic blocks."
                )
            } else {
                HSplitView {
                    moduleList.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    functionColumn.frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    graphs.frame(minWidth: 420)
                }
            }
        }
        .background(ConsoleStyle.background)
        .foregroundStyle(ConsoleStyle.text)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $pickingPrimary, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.primaryURL = url
                store.remember()
            }
        }
        .fileImporter(isPresented: $pickingSecondary, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.secondaryURL = url
                store.remember()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                IndicatorLamp(color: ConsoleStyle.amber)
                Button("Primary…", systemImage: "folder") { pickingPrimary = true }
                    .help("Choose the A-side snapshot generation (needs manifest.bin and memory.bin)")
                Text(store.primaryURL?.lastPathComponent ?? "none")
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(store.primaryURL == nil ? ConsoleStyle.muted : ConsoleStyle.text)
                    .help(store.primaryURL?.path ?? "No primary snapshot chosen")
            }
            Button {
                store.swap()
            } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.iconOnly)
            .disabled(store.running || (store.primaryURL == nil && store.secondaryURL == nil))
            .help("Swap primary and secondary snapshots")
            HStack(spacing: 6) {
                IndicatorLamp(color: ConsoleStyle.red)
                Button("Secondary…", systemImage: "folder") { pickingSecondary = true }
                    .help("Choose the B-side snapshot generation (needs manifest.bin and memory.bin)")
                Text(store.secondaryURL?.lastPathComponent ?? "none")
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(store.secondaryURL == nil ? ConsoleStyle.muted : ConsoleStyle.text)
                    .help(store.secondaryURL?.path ?? "No secondary snapshot chosen")
            }
            Spacer()
            if store.running { ProgressView().controlSize(.small) }
            Button("Compare", systemImage: "arrow.triangle.branch") { store.compare() }
                .disabled(store.running || store.primaryURL == nil || store.secondaryURL == nil)
                .help("Match executable images by the hash of their executable bytes")
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
    }

    private var instruments: some View {
        HStack(spacing: 8) {
            MainInstrument(label: "Images", value: String(format: "%03d", store.modules.count), color: ConsoleStyle.text)
            MainInstrument(label: "Identical", value: String(format: "%03d", store.identicalCount), color: ConsoleStyle.mint)
            MainInstrument(label: "Primary only", value: String(format: "%03d", store.primaryOnly), color: ConsoleStyle.amber)
            MainInstrument(label: "Secondary only", value: String(format: "%03d", store.secondaryOnly), color: ConsoleStyle.red)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                InstrumentLabel(text: "Status")
                Text(store.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ConsoleStyle.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .help(store.status)
            }
        }
        .padding(16).background(ConsoleStyle.panel)
    }

    private var moduleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader(title: "01 / Modules", trailing: "\(store.modules.count)")
            List(store.modules, selection: Binding(
                get: { store.selection },
                set: { module in if let module { store.loadFunctions(module) } }
            )) { module in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        IndicatorLamp(color: statusColor(module.status))
                        Text(module.name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                    }
                    Text(moduleDetail(module))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ConsoleStyle.muted)
                }
                .tag(module)
                .listRowBackground(store.selection?.id == module.id ? ConsoleStyle.well : Color.clear)
                .help("\(module.name)\n\(statusWord(module.status)) · \(byteLabel(module.execBytes)) · \(similarityLabel(module.similarity))")
            }
            .scrollContentBackground(.hidden)
        }
        .background(ConsoleStyle.background)
    }

    private var functionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleSectionHeader(title: "02 / Functions", trailing: functionSummary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(ConsoleStyle.muted)
                TextField("Filter functions", text: $store.functionFilter, prompt: Text("Filter functions").foregroundStyle(ConsoleStyle.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                if !store.functionFilter.isEmpty {
                    Button {
                        store.functionFilter = ""
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(ConsoleStyle.muted)
                    .help("Clear filter")
                }
            }
            .padding(10)
            .overlay(alignment: .bottom) { Rectangle().fill(ConsoleStyle.line).frame(height: 1) }
            List(store.visibleFunctions, selection: Binding(
                get: { store.functionSelection },
                set: { function in
                    if let function, let module = store.selection { store.loadGraph(module, function) }
                }
            )) { function in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(function.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        if function.address == store.entryAddress {
                            Text("ENTRY")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(0.8)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .foregroundStyle(ConsoleStyle.mint)
                                .background(ConsoleStyle.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ConsoleStyle.mint.opacity(0.4)))
                        }
                    }
                    Text("0x\(String(format: "%llx", function.address)) · \(byteLabel(function.size))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ConsoleStyle.muted)
                }
                .tag(function)
                .help("\(function.name)\n0x\(String(format: "%llx", function.address)) · \(byteLabel(function.size))")
            }
            .scrollContentBackground(.hidden)
        }
        .background(ConsoleStyle.background)
    }

    private var graphs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IndicatorLamp(color: sideColor)
                if let function = store.functionSelection {
                    Text(function.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Text("0x\(String(format: "%llx", function.address))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ConsoleStyle.muted)
                } else {
                    InstrumentLabel(text: store.selection == nil ? "No module selected" : "No function selected")
                }
                Spacer()
                InstrumentLabel(text: store.graphedSide, color: sideColor)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ConsoleStyle.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(ConsoleStyle.line).frame(height: 1) }
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    ConsoleSectionHeader(title: "03 / Calls", trailing: callSummary)
                    if store.graph == nil {
                        ConsoleEmptyState(title: "No function yet", message: "Pick a module, then a function, to open its call neighborhood.")
                    } else if store.graph?.calls.isEmpty == true {
                        ConsoleEmptyState(title: "No calls recorded", message: "This function makes no direct calls in the disassembled image.")
                    } else {
                        CallGraph(graph: store.graph, color: sideColor)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ConsoleSectionHeader(title: "04 / Blocks", trailing: blockSummary)
                    if store.graph == nil {
                        ConsoleEmptyState(title: "No function yet", message: "Basic blocks appear here once a function is selected.")
                    } else if store.graph?.blocks.isEmpty == true {
                        ConsoleEmptyState(title: "No blocks decoded", message: "The disassembler returned no basic blocks for this function.")
                    } else {
                        BlockGraph(graph: store.graph, color: sideColor)
                    }
                }
            }
        }
        .background(ConsoleStyle.background)
    }

    private var sideColor: Color {
        guard store.selection != nil else { return ConsoleStyle.muted }
        return statusColor(store.selection?.status ?? "")
    }

    private var callSummary: String {
        guard let graph = store.graph else { return "" }
        return graph.calls.count > CallGraph.shownCalls
            ? "\(CallGraph.shownCalls) of \(graph.calls.count)"
            : "\(graph.calls.count)"
    }

    private var blockSummary: String {
        guard let graph = store.graph else { return "" }
        return graph.blocks.count > BlockGraph.shownBlocks
            ? "\(BlockGraph.shownBlocks) of \(graph.blocks.count)"
            : "\(graph.blocks.count)"
    }

    private var functionSummary: String {
        guard !store.functions.isEmpty else { return "" }
        return store.functionFilter.isEmpty
            ? "\(store.functions.count)"
            : "\(store.visibleFunctions.count) of \(store.functions.count)"
    }

    private func moduleDetail(_ module: ExecModule) -> String {
        if module.status == "identical" {
            return "\(statusWord(module.status)) · \(byteLabel(module.execBytes)) · \(similarityLabel(module.similarity))"
        }
        return "\(statusWord(module.status)) · \(byteLabel(module.execBytes))"
    }

    private func similarityLabel(_ similarity: Double) -> String {
        let pct = similarity <= 1 ? similarity * 100 : similarity
        return String(format: "%.0f%%", pct)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "identical": ConsoleStyle.mint
        case "primary": ConsoleStyle.amber
        default: ConsoleStyle.red
        }
    }

    private func statusWord(_ status: String) -> String {
        switch status {
        case "identical": "match"
        case "primary": "primary only"
        default: "secondary only"
        }
    }

    private func byteLabel(_ size: Int) -> String {
        let formatted = InstrumentFormat.compactBytes(Int64(size))
        return "\(formatted.value) \(formatted.unit)"
    }
}

private struct CallGraph: View {
    static let shownCalls = 8
    let graph: ExecGraph?
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let graph else { return }
            let center = CGPoint(x: size.width / 2, y: 78)
            node(context, at: center, title: graph.name, address: graph.address, color: color)
            let calls = Array(graph.calls.prefix(Self.shownCalls))
            for (index, call) in calls.enumerated() {
                let x = size.width * (CGFloat(index) + 1) / CGFloat(calls.count + 1)
                let point = CGPoint(x: x, y: min(size.height - 44, 196))
                var edge = Path()
                edge.move(to: CGPoint(x: center.x, y: center.y + 22))
                edge.addLine(to: CGPoint(x: point.x, y: point.y - 22))
                context.stroke(edge, with: .color(color.opacity(0.7)), lineWidth: 1)
                node(context, at: point, title: call.name, address: call.address, color: color)
            }
            if graph.calls.count > calls.count {
                context.draw(
                    Text("+ \(graph.calls.count - calls.count) more")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ConsoleStyle.muted),
                    at: CGPoint(x: size.width / 2, y: min(size.height - 12, 228))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsoleStyle.well)
    }

    private func node(_ context: GraphicsContext, at point: CGPoint, title: String, address: Int, color: Color) {
        let rect = CGRect(x: point.x - 70, y: point.y - 20, width: 140, height: 40)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ConsoleStyle.panel))
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), lineWidth: 1)
        let shown = title.count > 20 ? String(title.prefix(19)) + "…" : title
        context.draw(
            Text(shown).font(.system(size: 9, design: .monospaced)).foregroundStyle(ConsoleStyle.text),
            at: CGPoint(x: point.x, y: point.y - 7)
        )
        context.draw(
            Text("0x\(String(format: "%llx", address))")
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(ConsoleStyle.muted),
            at: CGPoint(x: point.x, y: point.y + 9)
        )
    }
}

private struct BlockGraph: View {
    static let shownBlocks = 24
    let graph: ExecGraph?
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let graph, !graph.blocks.isEmpty else { return }
            let placed = layout(graph.blocks, width: size.width)
            var byAddress: [Int: CGPoint] = [:]
            for item in placed { byAddress[item.block.address] = item.center }
            for item in placed {
                for successor in item.block.successors {
                    guard let dest = byAddress[successor] else { continue }
                    var edge = Path()
                    edge.move(to: CGPoint(x: item.center.x, y: item.center.y + 34))
                    edge.addLine(to: CGPoint(x: dest.x, y: dest.y - 34))
                    context.stroke(edge, with: .color(color.opacity(0.65)), lineWidth: 1)
                }
            }
            for item in placed {
                let rect = CGRect(x: item.center.x - 88, y: item.center.y - 32, width: 176, height: 64)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ConsoleStyle.panel))
                context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), lineWidth: 1)
                context.draw(
                    Text("0x\(String(format: "%llx", item.block.address))")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(ConsoleStyle.muted),
                    at: CGPoint(x: item.center.x, y: item.center.y - 20)
                )
                let lines = item.block.instructions.prefix(2).map { insn in
                    insn.op.isEmpty ? insn.mnemonic : "\(insn.mnemonic) \(insn.op)"
                }
                var text = lines.joined(separator: "\n")
                if item.block.instructions.count > 2 {
                    text += "\n… +\(item.block.instructions.count - 2) more"
                }
                context.draw(
                    Text(text).font(.system(size: 9, design: .monospaced)).foregroundStyle(ConsoleStyle.text),
                    at: CGPoint(x: item.center.x, y: item.center.y + 8)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsoleStyle.well)
    }

    private struct Placed {
        let block: ExecBlock
        let center: CGPoint
    }

    private func layout(_ blocks: [ExecBlock], width: CGFloat) -> [Placed] {
        let columns = max(1, Int(width / 200))
        return blocks.prefix(Self.shownBlocks).enumerated().map { index, block in
            let column = index % columns
            let row = index / columns
            let x = 110 + CGFloat(column) * 200
            let y = 48 + CGFloat(row) * 92
            return Placed(block: block, center: CGPoint(x: x, y: y))
        }
    }
}
