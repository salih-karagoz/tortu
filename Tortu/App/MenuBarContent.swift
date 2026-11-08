import AppKit
import HistoryKit
import ScanCore
import SwiftData
import SwiftUI

/// The menu bar glyph: a stack of platters with dust settling onto it.
///
/// Drawn in code rather than shipped as an asset so that it is a template
/// image by construction, which is what lets the menu bar invert it on a dark
/// menu bar and dim it when the app is not active.
enum MenuBarGlyph {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            // The design draws in a top-left origin; AppKit's is bottom-left.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)

            context.addEllipse(in: CGRect(x: 3.5, y: 5.3, width: 11, height: 4.4))
            context.strokePath()

            for top in [7.5, 10.5] as [CGFloat] {
                context.move(to: CGPoint(x: 3.5, y: top))
                context.addLine(to: CGPoint(x: 3.5, y: top + 3))
                context.addCurve(
                    to: CGPoint(x: 14.5, y: top + 3),
                    control1: CGPoint(x: 3.5, y: top + 5.2),
                    control2: CGPoint(x: 14.5, y: top + 5.2)
                )
                context.addLine(to: CGPoint(x: 14.5, y: top))
                context.strokePath()
            }

            for (x, y, r) in [(12.5, 3.2, 0.9), (14.8, 1.9, 0.7), (11.0, 1.6, 0.6)] {
                context.fillEllipse(in: CGRect(
                    x: x - r, y: y - r, width: r * 2, height: r * 2
                ))
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuBarLabel: View {
    @Environment(VolumeMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image)
            Text(verbatim: monitor.freeSpaceText)
        }
        .accessibilityLabel(Text(verbatim: monitor.freeSpaceText))
    }
}

/// A window rather than a menu, so the free-space trace has somewhere to live.
struct MenuBarContent: View {
    @Environment(VolumeMonitor.self) private var monitor
    @Environment(CleanupController.self) private var cleanup
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var context

    @Query(sort: \VolumeSample.timestamp) private var volumeSamples: [VolumeSample]
    @Query(sort: \CategorySample.timestamp) private var categorySamples: [CategorySample]
    @Query(sort: \CleanupRecord.timestamp) private var cleanupRecords: [CleanupRecord]

    /// The last sixty readings, which at the default cadence is about the
    /// last fifteen hours.
    private static let traceLength = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            freeSpace
            trace
            fill
            Spacer(minLength: 0)
            Button { openWindow(id: "main") } label: {
                Text("menubar.open").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryAction)
        }
        .padding(14)
        .frame(width: 272, height: 300)
        .background(Tone.bg)
        .clipShape(RoundedRectangle(cornerRadius: Metric.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.panelRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
        .onChange(of: monitor.lastUpdate) { _, _ in
            guard let stats = monitor.stats else { return }
            HistoryRecorder(context: context).recordVolume(stats)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 19)
            Text(verbatim: "Tortu")
                .font(Face.display(15, 700))
                .tracking(-0.3)
                .foregroundStyle(Tone.ink)
            Spacer(minLength: 8)
            Dot(color: monitor.lastUpdate == nil ? Tone.b2 : Tone.acc)
            Text(verbatim: monitor.lastUpdate.map {
                $0.formatted(date: .omitted, time: .shortened)
            } ?? "—")
            .font(Face.text(11))
            .foregroundStyle(Tone.muted)
        }
    }

    private var freeSpace: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            BigNumber(measure: Figure.bytes(data.free), size: 26, unitSize: 12)
            Spacer(minLength: 6)
            if let rate = data.freeRate {
                Text(verbatim: Figure.perDay(rate.bytesPerDay).joined)
                    .font(Face.text(11.5, 500))
                    .foregroundStyle(Tone.sec)
            }
        }
    }

    @ViewBuilder
    private var trace: some View {
        let samples = Array(volumeSamples.suffix(Self.traceLength))
        VStack(alignment: .leading, spacing: 4) {
            FreeSpaceTrace(samples: samples)
                .frame(height: 44)
                // The dot at the end of the line is drawn around the last
                // point, so the line stops short of the edge to fit it.
                .padding(.trailing, 4)
            HStack {
                Note(verbatim: String(localized: "menubar.trace.start \(samples.count)"))
                    .sized(10)
                Spacer(minLength: 6)
                Note("menubar.trace.now").sized(10)
            }
        }
    }

    private var fill: some View {
        VStack(alignment: .leading, spacing: 6) {
            SplitBar(
                otherFraction: max(data.usedFraction - sedimentFraction, 0),
                sedimentFraction: sedimentFraction
            )
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: sedimentLine)
                    .font(Face.text(11))
                    .foregroundStyle(Tone.sec)
                Spacer(minLength: 6)
                if let exhaustion = data.exhaustion {
                    Text(verbatim: String(
                        localized: "menubar.full \(exhaustion.formatted(.dateTime.day().month(.abbreviated)))"
                    ))
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                }
            }
        }
    }

    private var sedimentLine: String {
        let used = Figure.percent(data.usedFraction)
        guard let plan = cleanup.plan else {
            return String(localized: "menubar.fill.unknown \(used)")
        }
        return String(
            localized: "menubar.fill \(Figure.bytes(plan.estimatedReclaim).joined) \(used)"
        )
    }

    private var sedimentFraction: Double {
        guard let plan = cleanup.plan, data.capacity.rawValue > 0 else { return 0 }
        return Double(plan.estimatedReclaim.rawValue) / Double(data.capacity.rawValue)
    }

    private var data: PanelData {
        PanelData.build(
            volumeSamples: volumeSamples,
            categorySamples: categorySamples,
            cleanupRecords: cleanupRecords,
            names: [:],
            stats: monitor.stats
        )
    }
}

/// The free-space trace: the same line as the waterline, with everything the
/// panel has room for taken off it.
private struct FreeSpaceTrace: View {
    let samples: [VolumeSample]

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2 else { return }
            let values = samples.map { Double($0.availableBytes) }
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, 1)

            func point(_ index: Int) -> CGPoint {
                let x = size.width * Double(index) / Double(values.count - 1)
                let y = size.height * (1 - (values[index] - low) / span)
                // Keep the stroke inside the box at both extremes.
                return CGPoint(x: x, y: 2 + y * (size.height - 6) / size.height)
            }

            var line = Path()
            line.addLines((0..<values.count).map(point))

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .color(Tone.area))
            context.stroke(
                line,
                with: .color(Tone.acc),
                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
            )

            let last = point(values.count - 1)
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                with: .color(Tone.acc)
            )
        }
        .accessibilityHidden(true)
    }
}
