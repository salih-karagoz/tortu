import SwiftUI

/// A row of columns, some a fixed width and the rest sharing what is left in
/// proportion to a weight.
///
/// The design specifies its tables in CSS grid terms — `30px 1fr 90px 1.1fr`
/// for the rule list, `22px 120px 50px …` for the history table — and the
/// column widths were measured against Turkish, which runs twenty to thirty
/// per cent longer than English. Approximating those with nested stacks loses
/// the measurement, so the grid is expressed directly instead.
///
/// Each subview is handed exactly its column width, so a cell aligns its own
/// content with an ordinary `frame(maxWidth:alignment:)`.
struct ColumnRow: Layout {
    enum Column: Equatable {
        case fixed(CGFloat)
        case flexible(CGFloat)
    }

    var columns: [Column]
    var spacing: CGFloat = 12
    var alignment: VerticalAlignment = .center

    func widths(in total: CGFloat) -> [CGFloat] {
        let gaps = spacing * CGFloat(max(columns.count - 1, 0))
        var fixed: CGFloat = 0
        var weight: CGFloat = 0
        for column in columns {
            switch column {
            case let .fixed(width): fixed += width
            case let .flexible(share): weight += share
            }
        }
        let free = max(total - gaps - fixed, 0)
        return columns.map { column in
            switch column {
            case let .fixed(width): width
            case let .flexible(share): weight > 0 ? free * share / weight : 0
            }
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let total = proposal.width ?? 0
        let widths = widths(in: total)
        let height = zip(subviews, widths).reduce(CGFloat.zero) { tallest, pair in
            max(tallest, pair.0.sizeThatFits(.init(width: pair.1, height: nil)).height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let widths = widths(in: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index < widths.count ? widths[index] : 0
            let height = subview.sizeThatFits(.init(width: width, height: nil)).height
            let y: CGFloat = switch alignment {
            case .top: bounds.minY
            case .bottom: bounds.maxY - height
            default: bounds.midY - height / 2
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: width, height: height)
            )
            x += width + spacing
        }
    }
}
