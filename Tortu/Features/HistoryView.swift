import AppKit
import Foundation
import ScanCore
import SwiftData
import SwiftUI

/// The History screen.
///
/// One row per cleanup, with the estimate and the outcome in adjacent
/// columns and drawn as two bars to one scale. The totals at the top are the
/// app's own report card: how much it has promised over its lifetime, how
/// much it has delivered, and the average gap between them.
struct HistoryView: View {
    /// Which runs are opened out, held by the window so that a row the user
    /// opened is still open the next time they look at this screen.
    @Binding var expanded: Set<Date>

    @Query(sort: \CleanupRecord.timestamp, order: .reverse) private var records: [CleanupRecord]

    private static let columns: [ColumnRow.Column] = [
        .fixed(22), .fixed(120), .fixed(50), .fixed(46),
        .fixed(72), .fixed(72), .fixed(64), .flexible(1),
    ]

    private var runs: [CleanupRecord] {
        records.filter { !$0.wasDryRun }
    }

    var body: some View {
        ScreenBody(bottom: 16) {
            ScreenHeader(title: "history.title", subtitle: subtitle) {
                Button(action: exportCSV) { Text("history.export") }
                    .buttonStyle(.secondaryAction)
                    .disabled(runs.isEmpty)
            }

            if runs.isEmpty {
                Placeholder(message: "history.empty")
            } else {
                totals
                table
                legend
            }
        }
    }

    private var subtitle: String {
        guard let earliest = runs.last else { return "" }
        return String(
            localized: "history.subtitle \(runs.count) \(earliest.timestamp.formatted(date: .long, time: .omitted))"
        )
    }

    // MARK: Totals

    private var totalReclaimed: Int64 { runs.reduce(0) { $0 + $1.reclaimedBytes } }
    private var totalEstimated: Int64 { runs.reduce(0) { $0 + $1.estimatedBytes } }

    private var averageDeviation: Double? {
        let deviations = runs.compactMap(\.deviation)
        guard !deviations.isEmpty else { return nil }
        return deviations.reduce(0, +) / Double(deviations.count)
    }

    private var totals: some View {
        HairBox(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
            ColumnRow(
                columns: [.flexible(1), .flexible(1), .flexible(1), .flexible(1.5)],
                spacing: 0,
                alignment: .top
            ) {
                totalCell(
                    label: "history.total.reclaimed",
                    measure: Figure.bytes(ByteCount(totalReclaimed)),
                    color: Tone.acct,
                    divider: false
                )
                totalCell(
                    label: "history.total.estimated",
                    measure: Figure.bytes(ByteCount(totalEstimated)),
                    color: Tone.sec,
                    divider: true
                )
                totalCell(
                    label: "history.total.deviation",
                    measure: Figure.Measure(
                        value: averageDeviation.map { Figure.percent($0) } ?? "—", unit: ""
                    ),
                    color: Tone.ink,
                    divider: true
                )
                HStack(spacing: 0) {
                    Hairline(axis: .vertical)
                    Text("history.total.note")
                        .font(Face.text(11.5))
                        .foregroundStyle(Tone.sec)
                        .lineSpacing(1.45)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func totalCell(
        label: LocalizedStringResource,
        measure: Figure.Measure,
        color: Color,
        divider: Bool
    ) -> some View {
        HStack(spacing: 0) {
            if divider { Hairline(axis: .vertical) }
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel(label)
                BigNumber(measure: measure, size: 24, unitSize: 12, color: color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.leading, divider ? 16 : 0)
            .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
    }

    // MARK: Table

    /// Every bar on the screen is drawn against the largest single cleanup,
    /// so the rows are comparable with each other rather than each filling
    /// its own cell.
    private var scale: Int64 {
        max(runs.map { max($0.estimatedBytes, $0.reclaimedBytes) }.max() ?? 1, 1)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnRow(columns: Self.columns) {
                Color.clear.frame(height: 1)
                SectionLabel("history.column.date")
                SectionLabel("history.column.rules")
                SectionLabel("history.column.paths")
                SectionLabel("history.column.estimated")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                SectionLabel("history.column.reclaimed")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                SectionLabel("history.column.difference")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Color.clear.frame(height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(runs) { record in
                        Hairline()
                        HistoryRow(
                            record: record,
                            columns: Self.columns,
                            scale: scale,
                            isFeatured: record.timestamp == runs.first?.timestamp,
                            isExpanded: expanded.contains(record.timestamp)
                        ) {
                            if expanded.contains(record.timestamp) {
                                expanded.remove(record.timestamp)
                            } else {
                                expanded.insert(record.timestamp)
                            }
                        }
                    }
                    Hairline()
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                GhostBar(height: 4).frame(width: 22)
                Text("cleanup.lastRun.estimated")
                    .font(Face.text(11))
                    .foregroundStyle(Tone.sec)
            }
            HStack(spacing: 6) {
                Rectangle().fill(Tone.acc).frame(width: 22, height: 4)
                Text("cleanup.lastRun.reclaimed")
                    .font(Face.text(11))
                    .foregroundStyle(Tone.sec)
            }
            Spacer(minLength: 0)
            Note(verbatim: String(
                localized: "history.legend.scale \(Figure.bytes(ByteCount(scale)).joined)"
            ))
        }
        .padding(.horizontal, 14)
    }

    // MARK: Export

    /// Writes the whole history out as CSV. Every figure the app has ever
    /// shown should be removable from it.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tortu-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["timestamp,rules,paths,estimated_bytes,reclaimed_bytes,skipped"]
        for record in runs {
            lines.append([
                ISO8601DateFormatter().string(from: record.timestamp),
                String(record.rules.count),
                String(record.pathCount),
                String(record.estimatedBytes),
                String(record.reclaimedBytes),
                String(record.skippedCount),
            ].joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let record: CleanupRecord
    let columns: [ColumnRow.Column]
    let scale: Int64
    let isFeatured: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                ColumnRow(columns: columns) {
                    Chevron(isOpen: isExpanded)

                    Text(verbatim: record.timestamp.formatted(
                        .dateTime.day().month(.abbreviated).hour().minute()
                    ))
                    .font(Face.text(12))
                    .foregroundStyle(Tone.ink)

                    Text(verbatim: Figure.count(record.rules.count))
                        .font(Face.display(12, 600))
                        .foregroundStyle(Tone.sec)

                    Text(verbatim: Figure.count(record.pathCount))
                        .font(Face.display(12, 600))
                        .foregroundStyle(Tone.sec)

                    Text(verbatim: Figure.bytes(ByteCount(record.estimatedBytes)).joined)
                        .font(Face.display(12, 600))
                        .foregroundStyle(Tone.sec)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Text(verbatim: Figure.bytes(ByteCount(record.reclaimedBytes)).joined)
                        .font(Face.display(12, 600))
                        .foregroundStyle(isFeatured ? Tone.acct : Tone.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Text(verbatim: record.deviation.map { Figure.percent($0) } ?? "—")
                        .font(Face.display(12, 600))
                        .foregroundStyle(Tone.sec)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        GhostBar(
                            height: 4,
                            fraction: Double(record.estimatedBytes) / Double(scale)
                        )
                        TrackBar(
                            fraction: Double(record.reclaimedBytes) / Double(scale),
                            height: 4,
                            fill: isFeatured ? Tone.acc : Tone.ink,
                            track: .clear
                        )
                    }
                    .padding(.leading, 6)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded { detail }
        }
    }

    /// What each rule was estimated at. There is deliberately no per-rule
    /// outcome column: the volume reports one figure for the whole run.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if record.rules.isEmpty {
                Note("history.detail.none")
            } else {
                HStack(spacing: 6) {
                    ForEach(record.rules.prefix(5)) { rule in
                        HairBox(
                            padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
                        ) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: rule.name)
                                    .font(Face.text(11, 600))
                                    .foregroundStyle(Tone.ink)
                                    .lineLimit(1)
                                Text(verbatim: Figure.bytes(
                                    ByteCount(rule.estimatedBytes)
                                ).joined)
                                .font(Face.display(12, 600))
                                .foregroundStyle(Tone.sec)
                            }
                        }
                    }
                    if record.rules.count > 5 {
                        Note(verbatim: String(
                            localized: "history.detail.more \(record.rules.count - 5)"
                        ))
                    }
                    Spacer(minLength: 0)
                }
            }
            if record.skippedCount > 0 {
                Note(verbatim: String(
                    localized: "cleanup.lastRun.skipped \(record.skippedCount)"
                ))
            }
        }
        .padding(.horizontal, 14 + 22 + 12)
        .padding(.bottom, 10)
    }
}

/// The disclosure triangle on a table row.
struct Chevron: View {
    let isOpen: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.addLines([
                CGPoint(x: size.width * 0.3, y: size.height * 0.15),
                CGPoint(x: size.width * 0.72, y: size.height * 0.5),
                CGPoint(x: size.width * 0.3, y: size.height * 0.85),
            ])
            context.stroke(
                path,
                with: .color(Tone.b2),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 10, height: 10)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
        .animation(.easeOut(duration: 0.12), value: isOpen)
        .accessibilityHidden(true)
    }
}
