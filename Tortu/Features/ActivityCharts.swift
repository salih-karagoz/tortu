import SwiftUI

/// The last few minutes of a measure, drawn as a filled trace.
///
/// A `Canvas` rather than Swift Charts, which draws every other chart in this
/// application. The difference is that those are charts of history — a few
/// dozen points that change when a measurement is taken — and this one is
/// redrawn every second with two hundred points in it. A chart framework
/// rebuilds its whole scale and its marks each time; a canvas draws two paths.
struct TraceChart: View {
    let trace: Trace
    /// The top of the scale. Nil means the tallest reading in the window
    /// sets it, which is the only honest choice for a rate that has no
    /// ceiling: there is no such thing as a full network.
    var ceiling: Double?
    var primary: Color = Tone.acc
    var secondary: Color = Tone.ink
    /// Drawn right to left, so the newest reading is always against the
    /// right-hand edge and the chart does not appear to grow out of the left
    /// while it is filling up.
    var capacity: Int = 200

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        for step in 1 ... 3 {
            let y = size.height * CGFloat(step) / 4
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: Metric.hairline)),
                with: .color(Tone.line)
            )
        }
        guard trace.count >= 2 else { return }

        let top = ceiling ?? trace.scale
        let slot = size.width / CGFloat(max(capacity - 1, 1))
        func point(_ values: [Double], _ index: Int) -> CGPoint {
            // The newest reading sits on the right edge; older ones walk
            // back from it, so the line scrolls rather than stretches.
            let fromRight = values.count - 1 - index
            let x = size.width - CGFloat(fromRight) * slot
            let fraction = min(max(values[index] / top, 0), 1)
            return CGPoint(x: x, y: size.height * (1 - fraction))
        }

        func line(_ values: [Double]) -> Path? {
            guard values.count >= 2 else { return nil }
            var path = Path()
            path.addLines((0 ..< values.count).map { point(values, $0) })
            return path
        }

        if let secondaryLine = line(trace.secondary), trace.peak > 0 {
            context.stroke(
                secondaryLine,
                with: .color(secondary.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1.25, lineJoin: .round)
            )
        }

        guard let primaryLine = line(trace.primary) else { return }
        var area = primaryLine
        let first = point(trace.primary, 0)
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: first.x, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .color(Tone.area))
        context.stroke(
            primaryLine,
            with: .color(primary),
            style: StrokeStyle(lineWidth: 1.75, lineJoin: .round)
        )

        let last = point(trace.primary, trace.primary.count - 1)
        context.fill(
            Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
            with: .color(primary)
        )
    }
}

/// One bar per core, in the order the kernel numbers them.
///
/// Worth its own strip because a single average hides the thing people
/// actually want to know: whether one core is pinned or all of them are
/// working. All the bars are drawn alike: this machine's cores come in two
/// speeds, but which index is which is not something the kernel states, and
/// colouring them on a guess would be a claim rather than a reading.
struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(cores.indices, id: \.self) { index in
                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(Tone.acc)
                                .frame(
                                    height: max(
                                        geometry.size.height * min(max(cores[index], 0), 1), 1
                                    )
                                )
                        }
                    }
                    .background(Tone.soft)
                    Text(verbatim: "\(index + 1)")
                        .font(Face.display(8.5, 500))
                        .foregroundStyle(Tone.muted)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A single bar split into named parts that add up to a whole.
///
/// Used for memory, where the question is never "how full" on its own but
/// "full of what". Identity is carried by lightness and by the key beneath
/// it, never by hue, which is the rule the rest of this design keeps.
struct CompositionBar: View {
    struct Part: Identifiable {
        let id: String
        let label: LocalizedStringResource
        let fraction: Double
        let color: Color

        init(_ id: String, _ label: LocalizedStringResource, _ fraction: Double, _ color: Color) {
            self.id = id
            self.label = label
            self.fraction = fraction.isFinite ? max(fraction, 0) : 0
            self.color = color
        }
    }

    let parts: [Part]
    var height: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(geometry.size.width * part.fraction, 0))
                    }
                    Spacer(minLength: 0)
                }
                .background(Tone.soft)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

            ChartKey(items: parts.map {
                ChartKey.Item(id: $0.id, label: String(localized: $0.label), color: $0.color)
            })
        }
        .accessibilityHidden(true)
    }
}
