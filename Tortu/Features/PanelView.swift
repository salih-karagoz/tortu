import HistoryKit
import RulesEngine
import ScanCore
import SwiftData
import SwiftUI

/// The Panel.
///
/// One chart at a time, chosen with the segmented picker above it, and three
/// standing numbers below. The picker holds whichever charts the user keeps,
/// in their order; editing that list happens inside the chart box rather than
/// in a sheet, so the thing being configured stays on screen while it is
/// configured.
struct PanelView: View {
    @Environment(VolumeMonitor.self) private var monitor
    @Environment(CleanupController.self) private var cleanup

    @Query(sort: \VolumeSample.timestamp) private var volumeSamples: [VolumeSample]
    @Query(sort: \CategorySample.timestamp) private var categorySamples: [CategorySample]
    @Query(sort: \CleanupRecord.timestamp) private var cleanupRecords: [CleanupRecord]

    @State private var charts: [PanelChart] = PanelBoardStore.load()
    /// Persisted, so the Panel reopens on the chart the user left it on.
    @AppStorage("panel.activeChart") private var activeRaw = PanelChart.waterline.rawValue
    #if DEBUG
    @State private var isEditing = DebugSnapshot.startsInChartEditor
    #else
    @State private var isEditing = false
    #endif

    private var active: Binding<PanelChart> {
        Binding(
            get: { PanelChart(rawValue: activeRaw) ?? .waterline },
            set: { activeRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScreenBody {
            ScreenHeader(title: "panel.title") {
                HStack(spacing: 6) {
                    Dot(color: monitor.lastUpdate == nil ? Tone.b2 : Tone.acc)
                    Note(verbatim: measurementLine).sized(12)
                }
            }

            strip
            chartBox
            summaryRow
            growthSection
        }
        .onChange(of: charts) { _, new in
            PanelBoardStore.save(new)
            if !new.contains(active.wrappedValue) { active.wrappedValue = .waterline }
        }
        .onAppear {
            cleanup.loadCatalog()
            if !charts.contains(active.wrappedValue) { active.wrappedValue = .waterline }
        }
    }

    // MARK: Chart strip

    private var strip: some View {
        HStack(spacing: 10) {
            SegmentPicker(
                options: charts.map { (value: $0, title: String(localized: $0.tab)) },
                selection: active
            )
            Spacer(minLength: 8)
            // While editing, the editor carries its own Done button; a second
            // one up here would be the same control twice.
            if !isEditing {
                Button { isEditing = true } label: { Text("panel.charts.edit") }
                    .buttonStyle(.secondaryAction)
            }
        }
        .frame(height: Metric.buttonHeight)
    }

    private var chartBox: some View {
        ChartFrame(
            label: isEditing ? "panel.charts.editorLabel" : active.wrappedValue.label,
            range: isEditing ? nil : String(localized: active.wrappedValue.range)
        ) {
            if isEditing {
                PanelChartEditor(charts: $charts) { isEditing = false }
            } else {
                chart(for: active.wrappedValue)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func chart(for chart: PanelChart) -> some View {
        switch chart {
        case .waterline:
            if data.hasVolumeHistory {
                WaterlineChart(data: data)
            } else {
                ChartEmpty(message: "chart.waterline.empty")
            }

        case .layers:
            if data.hasCategoryHistory {
                LayersChart(data: data)
            } else {
                ChartEmpty(message: "chart.layers.empty", action: scanAction)
            }

        case .regrowth:
            if data.ranked.count >= 1, data.hasCategoryHistory {
                RegrowthChart(data: data)
            } else {
                ChartEmpty(message: "chart.regrowth.empty", action: scanAction)
            }

        case .pace:
            if !data.ranked.isEmpty {
                PaceChart(data: data)
            } else {
                ChartEmpty(message: "chart.pace.empty", action: scanAction)
            }

        case .accuracy:
            if !data.cleanups.isEmpty {
                AccuracyChart(data: data)
            } else {
                ChartEmpty(message: "chart.accuracy.empty")
            }
        }
    }

    private var scanAction: (title: LocalizedStringResource, run: () -> Void)? {
        guard !cleanup.isBusy else { return nil }
        return (title: "panel.scanNow", run: { cleanup.analyse() })
    }

    // MARK: Summary

    private var summaryRow: some View {
        HStack(spacing: 10) {
            SummaryCard(
                label: "panel.free.label",
                measure: Figure.bytes(data.free),
                note: freeNote
            )
            SummaryCard(
                label: "panel.rate.label",
                measure: rateMeasure,
                note: String(localized: "panel.rate.note")
            )
            SummaryCard(
                label: "panel.forecast.label",
                measure: forecastMeasure,
                note: forecastNote,
                accented: true
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var freeNote: String {
        guard data.capacity.rawValue > 0 else {
            return String(localized: "panel.free.note.unknown")
        }
        return String(
            localized: "panel.free.note \(Figure.bytes(data.capacity).joined) \(Figure.percent(data.usedFraction))"
        )
    }

    private var rateMeasure: Figure.Measure {
        guard let rate = data.freeRate else {
            return Figure.Measure(value: "—", unit: "")
        }
        return Figure.perDay(rate.bytesPerDay)
    }

    private var forecastMeasure: Figure.Measure {
        guard let exhaustion = data.exhaustion else {
            return Figure.Measure(value: String(localized: "panel.forecast.none"), unit: "")
        }
        return Figure.Measure(
            value: exhaustion.formatted(.dateTime.day().month(.wide)),
            unit: ""
        )
    }

    private var forecastNote: String {
        guard let days = data.daysToExhaustion else {
            return String(localized: "panel.forecast.note.none")
        }
        return String(localized: "panel.forecast.note \(days)")
    }

    // MARK: Growth

    private var growthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("panel.growth.label")
                Spacer(minLength: 12)
                Note("panel.growth.note")
            }
            .padding(.horizontal, 2)

            if growthRows.isEmpty {
                // The same bar the waiting screens use, so the Panel says
                // "still measuring" in the same language as the rest of the
                // window rather than only in a sentence.
                VStack(alignment: .leading, spacing: 0) {
                    Note(cleanup.isBusy ? "panel.growth.scanning" : "panel.growth.empty")
                        .sized(11.5)
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    if cleanup.isBusy {
                        SweepBar(fraction: analysisFraction)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                        .strokeBorder(Tone.line, lineWidth: Metric.hairline)
                )
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(growthRows.enumerated()), id: \.element.id) { index, track in
                        GrowthCard(
                            track: track,
                            fraction: growthFraction(track),
                            featured: index == 0
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// How far the rule measurement has got, when one is under way.
    private var analysisFraction: Double? {
        if case let .analysing(state) = cleanup.phase { return state.fraction }
        return nil
    }

    private var growthRows: [CategoryTrack] {
        Array(data.ranked.prefix(4))
    }

    private func growthFraction(_ track: CategoryTrack) -> Double {
        guard let top = growthRows.first?.rate14, top > 0 else { return 0 }
        return (track.rate14 ?? 0) / top
    }

    // MARK: Data

    private var data: PanelData {
        PanelData.build(
            volumeSamples: volumeSamples,
            categorySamples: categorySamples,
            cleanupRecords: cleanupRecords,
            names: ruleNames,
            stats: monitor.stats
        )
    }

    private var ruleNames: [String: String] {
        Dictionary(
            cleanup.rules.map { ($0.id, $0.name.resolved()) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var measurementLine: String {
        guard let last = monitor.lastUpdate else {
            return String(localized: "panel.measurement.waiting")
        }
        // Weekday and date are formatted separately and joined, because a
        // single format with `.weekday()` in it puts the weekday last in
        // several locales, Turkish among them.
        let weekday = last.formatted(.dateTime.weekday(.wide))
        let date = last.formatted(date: .long, time: .omitted)
        return String(
            localized: "panel.measurement \(last.formatted(date: .omitted, time: .shortened)) \(weekday) \(date)"
        )
    }
}

/// One of the three standing numbers under the chart.
private struct SummaryCard: View {
    let label: LocalizedStringResource
    let measure: Figure.Measure
    let note: String
    var accented = false

    var body: some View {
        HairBox(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
            border: accented ? Tone.acc : Tone.line
        ) {
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel(label).tinted(accented ? Tone.acct : Tone.muted)
                BigNumber(
                    measure: measure,
                    color: accented ? Tone.acct : Tone.ink
                )
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Note(verbatim: note)
                    .tinted(accented ? Tone.sec : Tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One category in the growth row: a name, a rate, and a bar scaled to the
/// fastest one.
private struct GrowthCard: View {
    let track: CategoryTrack
    let fraction: Double
    let featured: Bool

    var body: some View {
        HairBox(padding: EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(track.name)
                        .font(Face.text(11.5, featured ? 600 : 500))
                        .foregroundStyle(featured ? Tone.acct : Tone.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Figure.gigabytesPerDay(track.rate14 ?? 0))
                        .font(Face.display(13, featured ? 700 : 600))
                        .foregroundStyle(featured ? Tone.acct : Tone.ink)
                }
                TrackBar(fraction: fraction, fill: featured ? Tone.acc : Tone.ink)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
