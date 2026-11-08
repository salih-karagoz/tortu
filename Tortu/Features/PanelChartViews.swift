import Charts
import Foundation
import HistoryKit
import ScanCore
import SwiftUI

// MARK: - Waterline

/// The signature chart: used space rising towards the edge of the volume.
///
/// Everything about it is shaped by one claim — that a disk filling up is a
/// slope, not a percentage. The solid line is what was measured, the dashed
/// one is where that slope leads, and the two meet the capacity line on a
/// date the user can put in a calendar. Each cleanup is a cliff in the solid
/// line, which is also the honest record of how quickly the ground was
/// regained last time.
struct WaterlineChart: View {
    let data: PanelData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chart
            axis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("chart.waterline.label"))
        .accessibilityValue(Text(verbatim: spokenSummary))
    }

    private var chart: some View {
        Chart {
            ForEach(gridValues, id: \.self) { value in
                RuleMark(y: .value("", value))
                    .foregroundStyle(Tone.line)
                    .lineStyle(StrokeStyle(lineWidth: Metric.hairline))
            }

            ForEach(data.used) { sample in
                AreaMark(
                    x: .value("date", sample.timestamp),
                    y: .value("used", Double(sample.bytes.rawValue))
                )
                .foregroundStyle(Tone.area)
                .interpolationMethod(.linear)
            }

            ForEach(data.used) { sample in
                LineMark(
                    x: .value("date", sample.timestamp),
                    y: .value("used", Double(sample.bytes.rawValue)),
                    series: .value("series", "measured")
                )
                .foregroundStyle(Tone.acc)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            ForEach(data.projection) { sample in
                LineMark(
                    x: .value("date", sample.timestamp),
                    y: .value("used", Double(sample.bytes.rawValue)),
                    series: .value("series", "projected")
                )
                .foregroundStyle(Tone.acc)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }

            RuleMark(y: .value("capacity", Double(data.capacity.rawValue)))
                .foregroundStyle(Tone.ink)
                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [2, 3]))

            if let today = data.used.last {
                RuleMark(x: .value("today", today.timestamp))
                    .foregroundStyle(Tone.b2)
                    .lineStyle(StrokeStyle(lineWidth: Metric.hairline, dash: [2, 3]))

                PointMark(
                    x: .value("date", today.timestamp),
                    y: .value("used", Double(today.bytes.rawValue))
                )
                .symbol {
                    Circle()
                        .fill(Tone.bg)
                        .overlay(Circle().strokeBorder(Tone.acc, lineWidth: 2))
                        .frame(width: 9, height: 9)
                }
            }

            if let exhaustion = data.exhaustion {
                PointMark(
                    x: .value("date", exhaustion),
                    y: .value("used", Double(data.capacity.rawValue))
                )
                .symbol { Circle().fill(Tone.ink).frame(width: 10, height: 10) }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.padding(.top, 10) }
        // Every piece of text on this chart is placed here rather than with
        // `.annotation`, so that each one sits at the distance the design
        // states and none of them can be clipped by the plot's edge.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                PinnedLabels.view(labels(proxy: proxy, in: geometry))
            }
        }
    }

    /// The dates under the plot. Drawn here rather than by Swift Charts so
    /// that "today" can be set in ink against the dates on either side of it.
    private var axis: some View {
        GeometryReader { geometry in
            PinnedLabels.view(xTicks.map { tick in
                PlotLabel(
                    id: "\(tick.fraction)",
                    text: tick.label,
                    pin: PinnedLabels.Pin(
                        x: geometry.size.width * tick.fraction, y: 0, anchor: .top
                    ),
                    color: tick.emphasised ? Tone.ink : Tone.muted,
                    weight: tick.emphasised ? 600 : 400,
                    size: 10
                )
            })
        }
        .frame(height: 16)
    }

    // MARK: Labels on the plot

    private func labels(proxy: ChartProxy, in geometry: GeometryProxy) -> [PlotLabel] {
        guard let anchor = proxy.plotFrame else { return [] }
        let plot = geometry[anchor]

        func positionX(_ date: Date) -> CGFloat? {
            proxy.position(forX: date).map { plot.minX + $0 }
        }
        func positionY(_ value: Double) -> CGFloat? {
            proxy.position(forY: value).map { plot.minY + $0 }
        }

        var labels: [PlotLabel] = []

        if let capacityY = positionY(Double(data.capacity.rawValue)) {
            labels.append(PlotLabel(
                id: "capacity",
                text: String(localized: "chart.waterline.capacity \(Figure.bytes(data.capacity).joined)"),
                pin: PinnedLabels.Pin(x: plot.minX + 8, y: capacityY - 3, anchor: .bottomLeading),
                color: Tone.ink
            ))

            if let exhaustion = data.exhaustion, let exhaustionX = positionX(exhaustion) {
                labels.append(PlotLabel(
                    id: "exhaustion",
                    text: exhaustion.formatted(.dateTime.day().month(.abbreviated)),
                    pin: PinnedLabels.Pin(
                        x: exhaustionX - 10, y: capacityY - 7, anchor: .bottomTrailing
                    ),
                    color: Tone.ink
                ))
            }
        }

        for value in gridValues {
            guard let gridY = positionY(value) else { continue }
            labels.append(PlotLabel(
                id: "grid-\(value)",
                text: gridLabel(value),
                pin: PinnedLabels.Pin(x: plot.minX + 8, y: gridY - 2, anchor: .bottomLeading)
            ))
        }

        if let today = data.used.last,
           let todayX = positionX(today.timestamp),
           let todayY = positionY(Double(today.bytes.rawValue)) {
            // Above and to the left of the dot where there is room, as the
            // design draws it. Where there is not — a volume with only a few
            // days of history puts the dot hard against the left edge — it
            // goes below instead, rather than across the projected line.
            let roomOnTheLeft = todayX - plot.minX > 140
            labels.append(PlotLabel(
                id: "today",
                text: todayLabel(today),
                pin: PinnedLabels.Pin(
                    x: roomOnTheLeft ? todayX - 9 : todayX + 9,
                    y: roomOnTheLeft ? todayY - 7 : todayY + 8,
                    anchor: roomOnTheLeft ? .bottomTrailing : .topLeading
                ),
                color: Tone.acct
            ))
        }

        if let cleanup = firstCleanupInWindow,
           let cleanupX = positionX(cleanup.date),
           let cleanupY = positionY(usedValue(at: cleanup.date)) {
            labels.append(PlotLabel(
                id: "cleanup",
                text: String(localized: "chart.waterline.cleanupMark"),
                pin: PinnedLabels.Pin(x: cleanupX + 7, y: cleanupY + 7, anchor: .topLeading)
            ))
        }

        return labels
    }

    // MARK: Scales

    private var yDomain: ClosedRange<Double> {
        let capacity = Double(data.capacity.rawValue)
        let floor = data.used.map { Double($0.bytes.rawValue) }.min() ?? capacity * 0.6
        let headroom = max(capacity - floor, capacity * 0.02)
        return (floor - headroom * 0.8)...(capacity + headroom * 0.09)
    }

    /// The date the projection runs to.
    private var horizon: Date {
        data.exhaustion ?? data.now.addingTimeInterval(7 * 86_400)
    }

    /// A little past the horizon, so the dot sitting on that date is drawn
    /// whole rather than cut in half by the edge of the plot.
    private var xDomain: ClosedRange<Date> {
        let start = data.used.first?.timestamp ?? data.now.addingTimeInterval(-86_400)
        guard horizon > start else { return start...start.addingTimeInterval(86_400) }
        let span = horizon.timeIntervalSince(start)
        return start...horizon.addingTimeInterval(span * 0.03)
    }

    /// Two or three round numbers inside the domain, never one so close to
    /// the capacity line that the two labels collide.
    private var gridValues: [Double] {
        let domain = yDomain
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [] }
        let rough = span / 3.2
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0]
            .map { $0 * magnitude }
            .first { $0 >= rough } ?? magnitude * 10
        let capacity = Double(data.capacity.rawValue)
        return stride(
            from: (domain.lowerBound / step).rounded(.up) * step,
            through: domain.upperBound,
            by: step
        )
        .filter { abs($0 - capacity) > step * 0.45 }
    }

    private struct Tick: Hashable {
        let date: Date
        let label: String
        let fraction: Double
        let emphasised: Bool
    }

    /// Ticks in order of importance, with any that would sit on top of one
    /// already kept dropped. Today is never the one dropped: it is the
    /// reference the rest of the chart is read against.
    private var xTicks: [Tick] {
        let domain = xDomain
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return [] }

        func fraction(_ date: Date) -> Double {
            date.timeIntervalSince(domain.lowerBound) / span
        }
        func short(_ date: Date) -> String {
            date.formatted(.dateTime.day().month(.abbreviated))
        }

        let today = data.used.last?.timestamp ?? data.now
        let todayAt = fraction(today)

        var candidates = [
            Tick(
                date: today, label: String(localized: "chart.today"),
                fraction: todayAt, emphasised: true
            ),
        ]
        if todayAt < 0.9 {
            candidates.append(Tick(
                date: horizon, label: short(horizon),
                fraction: fraction(horizon), emphasised: true
            ))
        }
        candidates.append(Tick(
            date: domain.lowerBound, label: short(domain.lowerBound),
            fraction: 0, emphasised: false
        ))
        for step in [0.33, 0.66] {
            let date = domain.lowerBound.addingTimeInterval(span * step)
            candidates.append(Tick(
                date: date, label: short(date), fraction: step, emphasised: false
            ))
        }

        var kept: [Tick] = []
        for candidate in candidates
        where !kept.contains(where: { abs($0.fraction - candidate.fraction) < 0.12 }) {
            kept.append(candidate)
        }
        return kept.sorted { $0.fraction < $1.fraction }
    }

    // MARK: Text

    private func gridLabel(_ value: Double) -> String {
        let measure = Figure.bytes(ByteCount(Int64(value)), fractionDigits: 0)
        // Only the lowest line carries the unit, as the design draws it.
        return value == gridValues.first ? measure.joined : measure.value
    }

    private func todayLabel(_ sample: Sample) -> String {
        String(localized: "chart.waterline.today \(Figure.bytes(sample.bytes).joined)")
    }

    private var firstCleanupInWindow: CleanupPoint? {
        guard let start = data.used.first?.timestamp else { return nil }
        return data.cleanups.first { $0.date >= start && $0.date <= data.now }
    }

    private func usedValue(at date: Date) -> Double {
        guard let nearest = data.used.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }) else { return 0 }
        return Double(nearest.bytes.rawValue)
    }

    private var spokenSummary: String {
        var parts = [
            String(localized: "chart.waterline.spoken.used \(Figure.bytes(data.capacity - data.free).joined) \(Figure.bytes(data.capacity).joined)"),
        ]
        if let days = data.daysToExhaustion, let exhaustion = data.exhaustion {
            parts.append(String(
                localized: "chart.waterline.spoken.full \(exhaustion.formatted(date: .long, time: .omitted)) \(days)"
            ))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Layers

/// What the sediment is made of, stacked, over time.
///
/// Bands are separated by lightness alone and named in the key, because the
/// design reserves colour for one thing. The thickest band takes the accent,
/// which means the eye lands on the layer worth acting on first.
struct LayersChart: View {
    let data: PanelData

    private var bands: [CategoryTrack] {
        Array(data.largest.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(bands) { band in
                    ForEach(band.series.samples) { sample in
                        AreaMark(
                            x: .value("date", sample.timestamp),
                            y: .value("bytes", Double(sample.bytes.rawValue)),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("rule", band.name))
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: bands.map(\.name),
                // The featured band is the accent, a shade off full strength:
                // at this area a solid accent stops being an accent.
                range: bands.indices.map { $0 == 0 ? Tone.acc.opacity(0.85) : Tone.step($0) }
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Tone.line)
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(Figure.axisBytes(ByteCount(Int64(bytes))))
                                .font(Face.text(10))
                                .foregroundStyle(Tone.muted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                .font(Face.text(10))
                                .foregroundStyle(Tone.muted)
                        }
                    }
                }
            }

            ChartKey(items: bands.indices.map { index in
                ChartKey.Item(
                    id: bands[index].id,
                    label: bands[index].name,
                    color: index == 0 ? Tone.acc.opacity(0.85) : Tone.step(index)
                )
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("chart.layers.label"))
        .accessibilityValue(Text(verbatim: bands.map {
            "\($0.name) \(Figure.bytes($0.latest).joined)"
        }.joined(separator: ", ")))
    }
}

// MARK: - Regrowth

/// How quickly a category comes back after it is cleared.
///
/// This is the chart that justifies keeping sixty days of measurements. A
/// cleanup shows as a drop; what matters is the angle of the line after it.
/// A category that returns to its old size within a week is one to automate,
/// not one to clean by hand.
struct RegrowthChart: View {
    let data: PanelData

    private var tracks: [CategoryTrack] {
        Array(data.ranked.prefix(3))
    }

    /// Each line's name, set at the end of the line rather than in a legend,
    /// and pushed apart where two lines finish at the same height.
    private func seriesLabels(proxy: ChartProxy, in geometry: GeometryProxy) -> [PlotLabel] {
        guard let anchor = proxy.plotFrame else { return [] }
        let plot = geometry[anchor]
        let lineHeight: CGFloat = 15

        var placed: [PlotLabel] = []
        var lastY: CGFloat = -.greatestFiniteMagnitude
        let ordered = tracks.enumerated()
            .compactMap { index, track -> (Int, CategoryTrack, CGFloat)? in
                guard let last = track.series.latest,
                      let y = proxy.position(forY: Double(last.bytes.rawValue))
                else { return nil }
                return (index, track, plot.minY + y)
            }
            .sorted { $0.2 < $1.2 }

        for (index, track, y) in ordered {
            let settled = max(y, lastY + lineHeight)
            lastY = settled
            placed.append(PlotLabel(
                id: track.id,
                text: track.name,
                pin: PinnedLabels.Pin(x: plot.maxX + 8, y: settled, anchor: .leading),
                color: index == 0 ? Tone.acct : Tone.ink,
                weight: index == 0 ? 600 : 500,
                size: 11
            ))
        }
        return placed
    }

    var body: some View {
        Chart {
            ForEach(data.cleanups) { cleanup in
                RuleMark(x: .value("cleanup", cleanup.date))
                    .foregroundStyle(Tone.b2)
                    .lineStyle(StrokeStyle(lineWidth: Metric.hairline, dash: [2, 3]))
            }

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                ForEach(track.series.samples) { sample in
                    LineMark(
                        x: .value("date", sample.timestamp),
                        y: .value("bytes", Double(sample.bytes.rawValue)),
                        series: .value("rule", track.name)
                    )
                    .foregroundStyle(index == 0 ? Tone.acc : Tone.step(index + 1))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }

                if let last = track.series.latest {
                    PointMark(
                        x: .value("date", last.timestamp),
                        y: .value("bytes", Double(last.bytes.rawValue))
                    )
                    .symbol {
                        Circle()
                            .fill(index == 0 ? Tone.acc : Tone.step(index + 1))
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Tone.line)
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(Figure.axisBytes(ByteCount(Int64(bytes))))
                            .font(Face.text(10))
                            .foregroundStyle(Tone.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(Face.text(10))
                            .foregroundStyle(Tone.muted)
                    }
                }
            }
        }
        // Room on the right for the labels that name each line in place of a
        // legend.
        .chartPlotStyle { $0.padding(.trailing, 118) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                PinnedLabels.view(seriesLabels(proxy: proxy, in: geometry))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("chart.regrowth.label"))
        .accessibilityValue(Text(verbatim: tracks.map {
            "\($0.name) \(Figure.bytes($0.latest).joined)"
        }.joined(separator: ", ")))
    }
}

// MARK: - Pace

/// Last week against the last fortnight, per category.
///
/// Two bars of the same unit on one row. Where the accent bar is the longer
/// of the pair the category is filling faster than it has been, which is the
/// only reading that distinguishes a habit from a one-off.
struct PaceChart: View {
    let data: PanelData

    private struct Row: Identifiable {
        let id: String
        let name: String
        let recent: Double
        let fortnight: Double
    }

    private var rows: [Row] {
        data.ranked.prefix(6).map {
            Row(
                id: $0.id, name: $0.name,
                recent: max($0.rate7 ?? 0, 0),
                fortnight: max($0.rate14 ?? 0, 0)
            )
        }
    }

    private var scale: Double {
        max(rows.flatMap { [$0.recent, $0.fortnight] }.max() ?? 1, 1)
    }

    private var recentLabel: String { String(localized: "chart.pace.recent") }
    private var fortnightLabel: String { String(localized: "chart.pace.fortnight") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Hairline() }
                line(row, featured: index == 0)
            }
            Spacer(minLength: 8)
            ChartKey(items: [
                ChartKey.Item(id: "recent", label: recentLabel, color: Tone.acc),
                ChartKey.Item(id: "fortnight", label: fortnightLabel, color: Tone.ink.opacity(0.42)),
            ])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("chart.pace.label"))
        .accessibilityValue(Text(verbatim: rows.map {
            "\($0.name) \(Figure.gigabytesPerDay($0.recent))"
        }.joined(separator: ", ")))
    }

    /// One category: its name, the two rates, and the two bars drawn to the
    /// same scale directly above one another. Where the accent bar is the
    /// longer of the pair, the category is filling faster than it was.
    private func line(_ row: Row, featured: Bool) -> some View {
        ColumnRow(
            columns: [.flexible(1), .fixed(50), .fixed(50), .flexible(1.7)],
            spacing: 12
        ) {
            Text(verbatim: row.name)
                .font(Face.text(12, featured ? 600 : 500))
                .foregroundStyle(featured ? Tone.acct : Tone.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(verbatim: Figure.gigabytesPerDay(row.recent))
                .font(Face.display(12.5, 600))
                .foregroundStyle(featured ? Tone.acct : Tone.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(verbatim: Figure.gigabytesPerDay(row.fortnight))
                .font(Face.display(12.5, 600))
                .foregroundStyle(Tone.sec)
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                TrackBar(fraction: row.recent / scale, height: 5, fill: Tone.acc)
                TrackBar(
                    fraction: row.fortnight / scale, height: 5,
                    fill: Tone.ink.opacity(0.42)
                )
            }
        }
        .frame(height: 34)
    }
}

// MARK: - Accuracy

/// What was promised beside what the volume gave back.
///
/// The app's one real claim is that it does not overstate. This chart is
/// where that claim is checked, cleanup by cleanup, including the runs that
/// came up short.
struct AccuracyChart: View {
    let data: PanelData

    private struct Row: Identifiable {
        let id: Date
        let label: String
        let estimated: Double
        let reclaimed: Double
    }

    private var rows: [Row] {
        data.cleanups.suffix(10).map {
            Row(
                id: $0.id,
                label: $0.date.formatted(.dateTime.day().month(.abbreviated)),
                estimated: Double($0.estimated.rawValue) / 1_000_000_000,
                reclaimed: Double($0.reclaimed.rawValue) / 1_000_000_000
            )
        }
    }

    private var estimatedLabel: String { String(localized: "chart.accuracy.estimated") }
    private var reclaimedLabel: String { String(localized: "chart.accuracy.reclaimed") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(rows) { row in
                    BarMark(
                        x: .value("cleanup", row.label),
                        y: .value("bytes", row.estimated),
                        width: 9
                    )
                    .position(by: .value("kind", estimatedLabel), span: .ratio(0.7))
                    .foregroundStyle(Tone.b2)

                    BarMark(
                        x: .value("cleanup", row.label),
                        y: .value("bytes", row.reclaimed),
                        width: 9
                    )
                    .position(by: .value("kind", reclaimedLabel), span: .ratio(0.7))
                    .foregroundStyle(Tone.acc)
                }
            }
            .chartXScale(domain: rows.map(\.label))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Tone.line)
                    AxisValueLabel {
                        if let gigabytes = value.as(Double.self) {
                            Text(gigabytes.formatted(.number.precision(.fractionLength(0))) + " GB")
                                .font(Face.text(10))
                                .foregroundStyle(Tone.muted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(Face.text(10))
                                .foregroundStyle(Tone.muted)
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                ChartKey(items: [
                    ChartKey.Item(id: "estimated", label: estimatedLabel, color: Tone.b2),
                    ChartKey.Item(id: "reclaimed", label: reclaimedLabel, color: Tone.acc),
                ])
                if let deviation = averageDeviation {
                    Text(String(localized: "chart.accuracy.deviation \(Figure.percent(deviation))"))
                        .font(Face.text(11, 500))
                        .foregroundStyle(Tone.sec)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("chart.accuracy.label"))
        .accessibilityValue(Text(verbatim: rows.map {
            "\($0.label) \($0.reclaimed.formatted(.number.precision(.fractionLength(1)))) GB"
        }.joined(separator: ", ")))
    }

    private var averageDeviation: Double? {
        let deviations = data.cleanups.compactMap(\.deviation)
        guard !deviations.isEmpty else { return nil }
        return deviations.reduce(0, +) / Double(deviations.count)
    }
}
