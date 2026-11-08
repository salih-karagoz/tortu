import SwiftUI

// MARK: - Working state
//
// What a screen shows while it is still measuring.
//
// The design specifies no waiting state, so this is built from what it does
// specify, and from one decision: a spinner says only that something is
// happening, and this is an application whose entire claim is that it
// measures honestly. So the waiting state measures out loud. It shows the
// figures as they climb, the path being read right now, how long it has been
// going, and — underneath — the shape of the table that is about to arrive.
// Nothing here is invented: a bar only fills when there is a real total to
// fill it against, and otherwise it sweeps.

/// One live reading in a working box: a figure and the label under it.
struct WorkingFigure {
    let label: LocalizedStringResource
    let measure: Figure.Measure

    init(_ label: LocalizedStringResource, _ measure: Figure.Measure) {
        self.label = label
        self.measure = measure
    }

    /// A count towards a known total, written as the pair it is.
    init(_ label: LocalizedStringResource, done: Int, of total: Int) {
        self.label = label
        measure = Figure.Measure(value: Figure.count(done), unit: "/ \(Figure.count(total))")
    }
}

/// The bar that says work is under way.
///
/// Determinate the moment a fraction is known, because a real measure always
/// beats a moving one; a sweep only where there is nothing to count towards.
/// The sweep is a solid block with a wake of `area` behind it — the same
/// nine per cent accent the waterline is filled with — rather than a
/// gradient, which the design rules out everywhere else.
struct SweepBar: View {
    var fraction: Double?
    var height: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One there-and-back sweep, in seconds.
    private let period: Double = 2.4

    var body: some View {
        Group {
            if let fraction {
                TrackBar(fraction: fraction, height: height, fill: Tone.acc)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            } else if reduceMotion {
                // Still clearly busy, without anything moving: a wash rather
                // than a filled bar, so it cannot be read as a percentage.
                Rectangle().fill(Tone.area).frame(height: height)
                    .background(Tone.soft)
            } else {
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
                        draw(in: canvas, size: size, date: context.date)
                    }
                }
                .frame(height: height)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in canvas: GraphicsContext, size: CGSize, date: Date) {
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Tone.soft))

        let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            / period
        // A cosine eases the block in and out of both ends on its own, which
        // is what a scan head does; a linear travel reads as a loading bar.
        let eased = (1 - cos(2 * .pi * turn)) / 2
        let block = max(size.width * 0.22, 40)
        let x = eased * (size.width - block)

        let goingRight = sin(2 * .pi * turn) > 0
        let wake = block * 1.7
        let wakeRect = CGRect(
            x: goingRight ? x - wake : x + block,
            y: 0,
            width: wake,
            height: size.height
        ).intersection(CGRect(origin: .zero, size: size))
        if !wakeRect.isNull {
            canvas.fill(Path(wakeRect), with: .color(Tone.area))
        }
        canvas.fill(
            Path(CGRect(x: x, y: 0, width: block, height: size.height)),
            with: .color(Tone.acc)
        )
    }
}

/// The readout above a waiting screen, and the table shape below it.
struct WorkingBox<Skeleton: View>: View {
    let title: LocalizedStringResource
    var figures: [WorkingFigure] = []
    /// The path or name the work is on right now.
    var detail: String?
    /// Known only when the work is a countable number of steps.
    var fraction: Double?
    /// When this piece of work started, for the elapsed clock.
    var started: Date?
    /// Offered only where stopping costs nothing: a walk that only reads.
    /// A removal already under way is never interrupted from here.
    var stop: (() -> Void)?
    @ViewBuilder var skeleton: Skeleton

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readout
            skeleton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LiveDot()
                    Text(title)
                        .font(Face.text(13, 500))
                        .foregroundStyle(Tone.ink)
                    Spacer(minLength: 12)
                    if let started {
                        Elapsed(since: started)
                    }
                    if let stop {
                        StopButton(action: stop)
                    }
                }

                if !figures.isEmpty {
                    HStack(alignment: .top, spacing: 32) {
                        ForEach(figures.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 2) {
                                BigNumber(
                                    measure: figures[index].measure,
                                    size: 26,
                                    unitSize: 12
                                )
                                SectionLabel(figures[index].label)
                            }
                        }
                    }
                }

                // Fixed height whether or not there is a path yet, so the
                // box does not jump the moment the first one arrives.
                Text(verbatim: detail ?? " ")
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 14, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))

            SweepBar(fraction: fraction)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The accent dot beside a live reading, breathing.
private struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Dot()
            .opacity(reduceMotion ? 1 : (dim ? 0.25 : 1))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: dim
            )
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// How long this has been running, which is the one thing every wait can
/// honestly report.
private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(verbatim: Duration
                .seconds(Int(max(0, context.date.timeIntervalSince(since))))
                .formatted(.time(pattern: .minuteSecond)))
                .font(Face.text(11.5))
                .foregroundStyle(Tone.muted)
        }
    }
}

/// A compact outlined button, short enough to sit on a readout line.
private struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("working.stop")
                .font(Face.text(11.5, 500))
                .foregroundStyle(Tone.sec)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.segmentRadius, style: .continuous)
                        .strokeBorder(Tone.b2, lineWidth: Metric.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skeleton

/// The table that is coming, drawn before there is anything to put in it.
///
/// It is laid out with the same `ColumnRow` columns as the real table, so
/// what arrives lands exactly where its outline was. The block widths vary
/// row by row from a fixed list rather than at random, so a waiting screen
/// looks the same twice and does not shimmer differently on every redraw.
struct SkeletonList: View {
    enum Cell {
        /// A checkbox.
        case check
        /// A name with its meta line under it.
        case lines(CGFloat)
        /// A single line of text.
        case line(CGFloat)
        /// A figure, set to the right of its column.
        case number(CGFloat)
        /// A proportion bar.
        case bar
        case blank
    }

    enum Style {
        /// One box, rows divided by hairlines: the Explorer and Finder tables.
        case table
        /// Separate outlined rows: the Cleanup rule list.
        case cards
    }

    let columns: [ColumnRow.Column]
    let cells: [Cell]
    var rows = 8
    var height: CGFloat = 38
    var spacing: CGFloat = 12
    var style: Style = .table

    var body: some View {
        switch style {
        case .table:
            VStack(spacing: 0) {
                ForEach(0 ..< rows, id: \.self) { index in
                    if index > 0 { Hairline() }
                    SkeletonRow(
                        columns: columns,
                        cells: cells,
                        index: index,
                        height: height,
                        spacing: spacing
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                    .strokeBorder(Tone.line, lineWidth: Metric.hairline)
            )

        case .cards:
            VStack(spacing: 6) {
                ForEach(0 ..< rows, id: \.self) { index in
                    SkeletonRow(
                        columns: columns,
                        cells: cells,
                        index: index,
                        height: height,
                        spacing: spacing
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                            .strokeBorder(Tone.line, lineWidth: Metric.hairline)
                    )
                }
            }
        }
    }
}

private struct SkeletonRow: View {
    let columns: [ColumnRow.Column]
    let cells: [SkeletonList.Cell]
    let index: Int
    let height: CGFloat
    let spacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faded = false

    /// Fixed widths, walked through, so no two rows next to each other are
    /// the same length and no row changes length between redraws.
    private static let jitter: [CGFloat] = [0.88, 0.57, 0.76, 0.49, 0.82, 0.64, 0.93, 0.70]

    private func width(_ fraction: CGFloat, _ cell: Int) -> CGFloat {
        fraction * Self.jitter[(index * 3 + cell) % Self.jitter.count]
    }

    var body: some View {
        ColumnRow(columns: columns, spacing: spacing) {
            ForEach(cells.indices, id: \.self) { cell in
                content(cells[cell], at: cell)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .opacity(reduceMotion ? 0.65 : (faded ? 0.4 : 0.95))
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 1.3)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.09),
            value: faded
        )
        .onAppear { faded = true }
    }

    @ViewBuilder
    private func content(_ cell: SkeletonList.Cell, at position: Int) -> some View {
        switch cell {
        case .check:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Tone.soft)
                .frame(width: 15, height: 15)
        case let .lines(fraction):
            VStack(alignment: .leading, spacing: 5) {
                Block(fraction: width(fraction, position), height: 8, color: Tone.soft)
                Block(
                    fraction: width(fraction, position + 1) * 0.72,
                    height: 6,
                    color: Tone.softer
                )
            }
        case let .line(fraction):
            Block(fraction: width(fraction, position), height: 7, color: Tone.soft)
        case let .number(fraction):
            Block(
                fraction: width(fraction, position),
                height: 9,
                color: Tone.soft,
                alignment: .trailing
            )
        case .bar:
            Block(fraction: 1, height: 4, color: Tone.soft)
                .padding(.trailing, 10)
        case .blank:
            Color.clear.frame(height: 1)
        }
    }
}

/// One grey block of a skeleton row, sized as a share of its column.
private struct Block: View {
    let fraction: CGFloat
    let height: CGFloat
    let color: Color
    var alignment: Alignment = .leading

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(color)
                .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
        .frame(height: height)
    }
}
