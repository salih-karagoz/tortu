import SwiftUI

/// The box every chart is drawn in.
///
/// One frame for all of them is what keeps a panel of five different charts
/// reading as one instrument rather than as five widgets: the same hairline,
/// the same uppercase label at the top left, the same span note at the top
/// right, and the drawing itself running the full width inside.
struct ChartFrame<Content: View>: View {
    let label: LocalizedStringResource
    var range: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(label)
                Spacer(minLength: 12)
                if let range {
                    Note(verbatim: range)
                }
            }
            .padding(.horizontal, 16)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
    }
}

/// What a chart shows when it has nothing to show.
///
/// It says which measurement is missing and, where the user can do something
/// about it, offers the one action that would produce it. An empty chart that
/// explains itself is worth more than a plausible-looking chart of nothing.
struct ChartEmpty: View {
    let message: LocalizedStringResource
    var action: (title: LocalizedStringResource, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(Face.text(12))
                .foregroundStyle(Tone.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.run) { Text(action.title) }
                    .buttonStyle(.secondaryAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The key beneath a chart that carries more than one series.
///
/// Identity is carried by the name; the swatch is only there so the eye can
/// find the band. The names are set in ink, as the design asks, rather than
/// in the colour of the series they stand for.
struct ChartKey: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let color: Color
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(item.color)
                        .frame(width: 8, height: 8)
                    Text(item.label)
                        .font(Face.text(11, 500))
                        .foregroundStyle(Tone.ink)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
