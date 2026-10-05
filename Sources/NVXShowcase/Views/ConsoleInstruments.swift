import SwiftUI

/// Shared instrument faces. Only the numerals glow; labels and log text stay crisp.
enum ConsoleStyle {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.068)
    static let panel = Color(red: 0.085, green: 0.099, blue: 0.102)
    static let well = Color(red: 0.035, green: 0.044, blue: 0.047)
    static let line = Color.white.opacity(0.10)
    static let text = Color(red: 0.88, green: 0.91, blue: 0.90)
    static let muted = Color(red: 0.54, green: 0.61, blue: 0.60)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.32)
    static let mint = Color(red: 0.47, green: 0.89, blue: 0.75)
    static let red = Color(red: 1.0, green: 0.43, blue: 0.37)
}

struct InstrumentLabel: View {
    let text: String
    var color: Color = ConsoleStyle.muted
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.2).foregroundStyle(color).lineLimit(1)
    }
}

struct IndicatorLamp: View {
    var color: Color = ConsoleStyle.mint
    var lit = true
    var body: some View {
        Circle().fill(lit ? color : color.opacity(0.15))
            .frame(width: 5, height: 5)
            .shadow(color: lit ? color.opacity(0.55) : .clear, radius: 3)
            .accessibilityHidden(true)
    }
}

/// Vector seven-segment numerals: stable widths, no font download, no update animation.
struct SegmentNumber: View {
    let value: String
    var height: CGFloat = 40
    var color: Color = ConsoleStyle.amber

    private static let masks: [Character: Set<Int>] = [
        "0": [0, 1, 2, 3, 4, 5], "1": [1, 2], "2": [0, 1, 6, 4, 3],
        "3": [0, 1, 2, 3, 6], "4": [5, 6, 1, 2], "5": [0, 5, 6, 2, 3],
        "6": [0, 5, 4, 3, 2, 6], "7": [0, 1, 2], "8": [0, 1, 2, 3, 4, 5, 6],
        "9": [0, 1, 2, 3, 5, 6], "-": [6],
    ]
    private var width: CGFloat {
        value.reduce(0) { $0 + ((":.".contains($1)) ? height * 0.19 : height * 0.61) }
    }

    var body: some View {
        Canvas { context, _ in
            var x: CGFloat = 0
            for char in value {
                if char == ":" || char == "." {
                    let ys: [CGFloat] = char == ":" ? [0.32, 0.68] : [0.92]
                    for y in ys {
                        context.fill(Path(ellipseIn: CGRect(x: x + height * 0.04,
                            y: y * height, width: height * 0.075, height: height * 0.075)), with: .color(color))
                    }
                    x += height * 0.19
                    continue
                }
                // Top, upper right, lower right, bottom, lower left, upper left, middle.
                let bars: [[CGPoint]] = [
                    horizontal(0.02), vertical(0.43, 0.07), vertical(0.43, 0.53),
                    horizontal(0.90), vertical(0.02, 0.53), vertical(0.02, 0.07), horizontal(0.46),
                ]
                for (i, points) in bars.enumerated() {
                    var path = Path()
                    path.addLines(points.map { CGPoint(x: x + $0.x * height, y: $0.y * height) })
                    path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(Self.masks[char, default: []].contains(i) ? 1 : 0.055)))
                }
                x += height * 0.61
            }
        }
        .frame(width: width, height: height)
        .shadow(color: color.opacity(0.18), radius: 4)
        .accessibilityLabel(value)
    }

    private func horizontal(_ y: CGFloat) -> [CGPoint] {
        [(0.07,y+0.04),(0.12,y),(0.42,y),(0.47,y+0.04),(0.42,y+0.08),(0.12,y+0.08)]
            .map { CGPoint(x: $0.0, y: $0.1) }
    }
    private func vertical(_ x: CGFloat, _ y: CGFloat) -> [CGPoint] {
        [(x+0.04,y),(x+0.08,y+0.05),(x+0.08,y+0.32),(x+0.04,y+0.37),(x,y+0.32),(x,y+0.05)]
            .map { CGPoint(x: $0.0, y: $0.1) }
    }
}

struct MainInstrument: View {
    let label: String
    let value: String
    var unit: String = ""
    var color: Color = ConsoleStyle.amber
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            InstrumentLabel(text: label)
            HStack(alignment: .bottom, spacing: 6) {
                SegmentNumber(value: value, height: 35, color: color)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ConsoleStyle.muted).padding(.bottom, 2)
                }
            }
        }
        .frame(minWidth: 100, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }
}

struct ResourceInstrument: View {
    let label: String
    let value: String
    var unit: String = ""
    let detail: String
    /// Nil means unavailable, not an empty or fabricated utilization reading.
    var fraction: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IndicatorLamp(lit: value != "—")
                InstrumentLabel(text: label)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 22, weight: .medium, design: .monospaced))
                    .monospacedDigit().foregroundStyle(ConsoleStyle.mint)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(unit).font(.system(size: 11, design: .monospaced)).foregroundStyle(ConsoleStyle.muted)
            }
            if let fraction {
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        ForEach(0..<24, id: \.self) { index in
                            Rectangle().fill(ConsoleStyle.mint.opacity(Double(index) / 24 < max(0, min(1, fraction)) ? 0.8 : 0.07))
                        }
                    }.frame(width: proxy.size.width)
                }.frame(height: 4).accessibilityHidden(true)
            } else {
                Rectangle().fill(ConsoleStyle.line).frame(height: 1).padding(.vertical, 1.5)
            }
            Text(detail).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ConsoleStyle.muted).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 28, alignment: .topLeading).help(detail)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsoleStyle.well, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ConsoleStyle.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit). \(detail)")
    }
}

struct ConsoleSectionHeader: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            InstrumentLabel(text: title)
            Spacer()
            InstrumentLabel(text: trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(ConsoleStyle.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(ConsoleStyle.line).frame(height: 1) }
    }
}

struct ConsoleEmptyState: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(">").foregroundStyle(ConsoleStyle.mint)
                Text(title).foregroundStyle(ConsoleStyle.text)
            }
            Text(message).foregroundStyle(ConsoleStyle.muted).lineSpacing(4)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
