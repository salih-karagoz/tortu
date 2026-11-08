import SwiftUI

/// Places each label so that one of its own corners lands on a given point,
/// and keeps it inside the bounds.
///
/// Swift Charts can attach a label to a mark with `.annotation`, but the
/// placement it chooses is relative to the mark's bounding box, not to the
/// point, and a label that would leave the plot is silently clipped rather
/// than pulled back. The waterline puts text against a gridline, beside a
/// dot and at both ends of an axis, at distances the design states in pixels,
/// so those positions are computed and placed directly instead.
struct PinnedLabels: Layout {
    struct Pin: Equatable {
        /// Where the label's anchor should land, in the layout's own space.
        var x: CGFloat
        var y: CGFloat
        /// Which part of the label lands on that point. `.bottomLeading`
        /// puts the label above and to the right of it.
        var anchor: UnitPoint = .topLeading
        /// Whether to pull the label back inside the bounds when it would
        /// otherwise hang over an edge.
        var clamped = true
    }

    var pins: [Pin]

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for (index, subview) in subviews.enumerated() {
            guard index < pins.count else {
                subview.place(at: .zero, proposal: .init(width: 0, height: 0))
                continue
            }
            let pin = pins[index]
            let size = subview.sizeThatFits(.unspecified)
            var x = bounds.minX + pin.x - size.width * pin.anchor.x
            var y = bounds.minY + pin.y - size.height * pin.anchor.y
            if pin.clamped {
                x = min(max(x, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
                y = min(max(y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        }
    }
}

/// One piece of text pinned onto a plot.
struct PlotLabel: Identifiable {
    let id: String
    var text: String
    var pin: PinnedLabels.Pin
    var color: Color = Tone.muted
    var weight: Double = 600
    var size: CGFloat = 10.5
}

extension PinnedLabels {
    /// Builds the layout and its labels from one list, so the pins and the
    /// subviews cannot fall out of step.
    @MainActor
    static func view(_ labels: [PlotLabel]) -> some View {
        PinnedLabels(pins: labels.map(\.pin)) {
            ForEach(labels) { label in
                Text(verbatim: label.text)
                    .font(Face.text(label.size, label.weight))
                    .foregroundStyle(label.color)
                    .fixedSize()
            }
        }
    }
}
