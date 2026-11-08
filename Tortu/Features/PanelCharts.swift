import Foundation
import SwiftUI

/// The charts the Panel can show.
///
/// The waterline is the one the product is built around and cannot be turned
/// off. The other four were chosen because each answers a question that only
/// a stored series can answer, and that none of the others answers:
///
/// - `layers`   — what the sediment is made of, and which layer is thickening.
/// - `regrowth` — how fast a category comes back after it is cleared. This is
///                the number that decides whether cleaning a thing is worth
///                doing again next week.
/// - `pace`     — last week against the last fortnight, which is the only
///                pairing that says whether a category is speeding up.
/// - `accuracy` — the estimate beside what the volume actually gave back, so
///                the user can decide how much to trust the figures above.
///
/// Deliberately absent: anything that is a snapshot rather than a series. A
/// pie of current sizes would duplicate the Explorer, and the summary boxes
/// already carry the three standing numbers.
enum PanelChart: String, CaseIterable, Identifiable, Sendable {
    case waterline
    case layers
    case regrowth
    case pace
    case accuracy

    var id: String { rawValue }

    /// The waterline is always present and always first.
    var isPermanent: Bool { self == .waterline }

    /// Short, for the segmented picker.
    var tab: LocalizedStringResource {
        switch self {
        case .waterline: "chart.waterline.tab"
        case .layers: "chart.layers.tab"
        case .regrowth: "chart.regrowth.tab"
        case .pace: "chart.pace.tab"
        case .accuracy: "chart.accuracy.tab"
        }
    }

    /// The uppercase label at the top left of the box.
    var label: LocalizedStringResource {
        switch self {
        case .waterline: "chart.waterline.label"
        case .layers: "chart.layers.label"
        case .regrowth: "chart.regrowth.label"
        case .pace: "chart.pace.label"
        case .accuracy: "chart.accuracy.label"
        }
    }

    /// The note at the top right: what span the chart covers.
    var range: LocalizedStringResource {
        switch self {
        case .waterline: "chart.waterline.range"
        case .layers: "chart.layers.range"
        case .regrowth: "chart.regrowth.range"
        case .pace: "chart.pace.range"
        case .accuracy: "chart.accuracy.range"
        }
    }

    /// One line in the editor saying what the chart is for.
    var purpose: LocalizedStringResource {
        switch self {
        case .waterline: "chart.waterline.purpose"
        case .layers: "chart.layers.purpose"
        case .regrowth: "chart.regrowth.purpose"
        case .pace: "chart.pace.purpose"
        case .accuracy: "chart.accuracy.purpose"
        }
    }
}

/// Which charts the user keeps, in which order.
///
/// Stored as an ordered list of identifiers rather than as a set of flags, so
/// that order survives too. Unknown identifiers are dropped on read, which is
/// what makes it safe to remove a chart in a later version.
enum PanelBoardStore {
    static let defaultsKey = "panel.charts"
    static let defaultCharts: [PanelChart] = PanelChart.allCases

    static func load(from defaults: UserDefaults = AppDefaults.store) -> [PanelChart] {
        guard let raw = defaults.string(forKey: defaultsKey) else { return defaultCharts }
        var seen: Set<PanelChart> = []
        var charts = raw
            .split(separator: ",")
            .compactMap { PanelChart(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        if let index = charts.firstIndex(where: \.isPermanent) {
            charts.insert(charts.remove(at: index), at: 0)
        } else {
            charts.insert(.waterline, at: 0)
        }
        return charts
    }

    static func save(_ charts: [PanelChart], to defaults: UserDefaults = AppDefaults.store) {
        defaults.set(charts.map(\.rawValue).joined(separator: ","), forKey: defaultsKey)
    }
}

/// The in-place editor: which charts appear in the picker, and in what order.
///
/// It takes over the chart box rather than opening a sheet, because the thing
/// being edited is the box itself and a sheet would hide it.
struct PanelChartEditor: View {
    @Binding var charts: [PanelChart]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element) { index, chart in
                if index > 0 { Hairline() }
                row(for: chart, at: index)
            }
            Spacer(minLength: 10)
            HStack {
                Note("chart.editor.hint")
                Spacer(minLength: 12)
                Button(action: onDone) { Text("chart.editor.done") }
                    .buttonStyle(.primaryAction)
            }
        }
    }

    /// Selected charts in their chosen order, then the unselected ones, so
    /// adding a chart does not move the rows the user is looking at.
    private var ordered: [PanelChart] {
        charts + PanelChart.allCases.filter { !charts.contains($0) }
    }

    private func row(for chart: PanelChart, at index: Int) -> some View {
        let isOn = charts.contains(chart)
        let position = charts.firstIndex(of: chart)

        return HStack(spacing: 12) {
            Button {
                toggle(chart)
            } label: {
                CheckBox(isOn: isOn, isEnabled: !chart.isPermanent)
            }
            .buttonStyle(.plain)
            .disabled(chart.isPermanent)

            VStack(alignment: .leading, spacing: 1) {
                Text(chart.label)
                    .font(Face.text(13, 600))
                    .foregroundStyle(isOn ? Tone.ink : Tone.sec)
                Note(chart.purpose)
                    .tinted(Tone.muted)
            }
            Spacer(minLength: 12)

            if chart.isPermanent {
                Badge("chart.editor.always")
            } else if let position {
                HStack(spacing: 4) {
                    MoveButton(direction: .up) { move(from: position, by: -1) }
                        .disabled(position <= 1)
                    MoveButton(direction: .down) { move(from: position, by: 1) }
                        .disabled(position >= charts.count - 1)
                }
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }

    private func toggle(_ chart: PanelChart) {
        guard !chart.isPermanent else { return }
        if let index = charts.firstIndex(of: chart) {
            charts.remove(at: index)
        } else {
            charts.append(chart)
        }
    }

    private func move(from index: Int, by offset: Int) {
        let destination = index + offset
        // The waterline holds position zero, so nothing may move into it.
        guard destination >= 1, destination < charts.count else { return }
        charts.swapAt(index, destination)
    }
}

/// A small triangle. Drawn rather than taken from the symbol set, because the
/// design carries no icons at all beyond the mark in the sidebar.
private struct MoveButton: View {
    enum Direction { case up, down }

    let direction: Direction
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Canvas { context, size in
                var path = Path()
                let inset: CGFloat = 3
                let top = CGPoint(x: size.width / 2, y: inset)
                let left = CGPoint(x: inset, y: size.height - inset)
                let right = CGPoint(x: size.width - inset, y: size.height - inset)
                switch direction {
                case .up: path.addLines([left, top, right])
                case .down: path.addLines([
                    CGPoint(x: inset, y: inset),
                    CGPoint(x: size.width / 2, y: size.height - inset),
                    CGPoint(x: size.width - inset, y: inset),
                ])
                }
                path.closeSubpath()
                context.fill(path, with: .color(Tone.sec))
            }
            .frame(width: 11, height: 9)
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: Metric.segmentRadius, style: .continuous)
                    .strokeBorder(Tone.b2, lineWidth: Metric.hairline)
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            direction == .up
                ? Text("chart.editor.moveUp") : Text("chart.editor.moveDown")
        )
    }
}
