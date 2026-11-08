import AppKit
import SwiftUI

// MARK: - Text roles
//
// Each of these is one line of the type scale in DESIGN.md. They exist as
// views rather than as modifiers so that a size can only be set in one place;
// the screens never name a point size.

/// The small uppercase heading above every box.
struct SectionLabel: View {
    private let text: String
    private var color: Color = Tone.muted

    init(_ resource: LocalizedStringResource) {
        text = String(localized: resource).displayUppercase
    }

    init(verbatim: String) {
        text = verbatim.displayUppercase
    }

    func tinted(_ color: Color) -> SectionLabel {
        var copy = self
        copy.color = color
        return copy
    }

    var body: some View {
        Text(text)
            .font(Face.text(10.5, 600))
            .tracking(0.84)
            .foregroundStyle(color)
    }
}

/// The note that sits opposite a section label, and every small aside.
struct Note: View {
    private let text: Text
    private var color: Color = Tone.muted
    private var size: CGFloat = 11

    init(_ resource: LocalizedStringResource) { text = Text(resource) }
    init(verbatim: String) { text = Text(verbatim) }

    func tinted(_ color: Color) -> Note {
        var copy = self
        copy.color = color
        return copy
    }

    func sized(_ size: CGFloat) -> Note {
        var copy = self
        copy.size = size
        return copy
    }

    var body: some View {
        text
            .font(Face.text(size))
            .foregroundStyle(color)
    }
}

/// The screen's own name, top left.
struct ScreenTitle: View {
    private let text: Text

    init(_ resource: LocalizedStringResource) { text = Text(resource) }

    var body: some View {
        text
            .font(Face.display(22, 600))
            .tracking(-0.44)
            .foregroundStyle(Tone.ink)
    }
}

/// A large figure with its unit set beside it.
///
/// The unit is deliberately a separate run: it is smaller, lighter and a
/// different colour, and letting it inherit the figure's size is the single
/// most common way this design gets flattened back into something generic.
struct BigNumber: View {
    let measure: Figure.Measure
    var size: CGFloat = 28
    var unitSize: CGFloat = 13
    var color: Color = Tone.ink
    var unitColor: Color = Tone.sec
    /// Space Grotesk for the unit matches the summary boxes; Inter matches
    /// the unit beside a size in a table row.
    var unitInText = false

    var body: some View {
        (
            Text(measure.value)
                .font(Face.display(size, 600))
                .foregroundStyle(color)
                + Text(measure.unit.isEmpty ? "" : " " + measure.unit)
                .font(unitInText ? Face.text(unitSize, 500) : Face.display(unitSize, 500))
                .foregroundStyle(unitColor)
        )
        .tracking(-0.025 * size)
    }
}

// MARK: - Containers

/// A hairline box: one pixel of `line`, eight points of radius.
///
/// Everything on every screen is inside one of these. The border is drawn as
/// an overlaid stroke rather than as a background so it stays exactly one
/// pixel at any backing scale.
struct HairBox<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    var border: Color = Tone.line
    var fill: Color = .clear
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: Metric.hairline)
            )
    }
}

/// One device pixel of `line`, in either direction.
struct Hairline: View {
    var axis: Axis = .horizontal
    var color: Color = Tone.line

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? Metric.hairline : nil,
                height: axis == .horizontal ? Metric.hairline : nil
            )
    }
}

/// A six point dot. Used for the accent beside a live reading and for the
/// marker on the selected navigation row.
struct Dot: View {
    var color: Color = Tone.acc
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - Bars

/// A filled bar on a `soft` track.
struct TrackBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var fill: Color = Tone.ink
    var track: Color = Tone.soft

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle()
                    .fill(fill)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// The sidebar's disk bar: other data, then sediment, then free.
///
/// Sediment is the only thing on this bar drawn in the accent, which is the
/// whole point of it — the user should be able to see at a glance how much of
/// a full disk the app believes it can give back.
struct SplitBar: View {
    let otherFraction: Double
    let sedimentFraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 2) {
                Rectangle().fill(Tone.ink)
                    .frame(width: max(width * min(max(otherFraction, 0), 1), 0))
                Rectangle().fill(Tone.acc)
                    .frame(width: max(width * min(max(sedimentFraction, 0), 1), 0))
                Spacer(minLength: 0)
            }
            .background(Tone.soft)
        }
        .frame(height: height)
    }
}

/// An outlined bar with nothing in it: what was estimated, as opposed to what
/// the volume actually gave back.
struct GhostBar: View {
    var height: CGFloat = 8
    var fraction: Double = 1

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .strokeBorder(
                    Tone.b2,
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .frame(width: geometry.size.width * min(max(fraction, 0), 1))
        }
        .frame(height: height)
    }
}

// MARK: - Controls

/// The segmented picker: active segment on `ink`, the rest plain.
struct SegmentPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let active = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(Face.text(12, active ? 600 : 500))
                        .foregroundStyle(active ? Tone.bg : Tone.sec)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Metric.segmentRadius, style: .continuous)
                                .fill(active ? Tone.ink : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(2)
        .overlay(
            RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
    }
}

/// The ordinary button: a hairline outline on the window ground.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Face.text(12.5, 500))
            .foregroundStyle(Tone.ink)
            .padding(.horizontal, 14)
            .frame(height: Metric.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Tone.soft : Tone.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous)
                    .strokeBorder(Tone.b2, lineWidth: Metric.hairline)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// The one button on a screen that commits something.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Face.text(12.5, 600))
            .foregroundStyle(Tone.onacc)
            .padding(.horizontal, 18)
            .frame(height: Metric.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous)
                    .fill(Tone.acc)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// A square uppercase chip: LOCKED, ADMIN, ALREADY COUNTED.
struct Badge: View {
    enum Kind {
        case neutral
        case accent
    }

    private let text: String
    private let kind: Kind

    init(_ resource: LocalizedStringResource, kind: Kind = .neutral) {
        text = String(localized: resource).displayUppercase
        self.kind = kind
    }

    var body: some View {
        Text(text)
            .font(Face.text(9.5, 600))
            .tracking(0.76)
            .foregroundStyle(kind == .accent ? Tone.acct : Tone.sec)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                Rectangle()
                    .strokeBorder(
                        kind == .accent ? Tone.acc : Tone.b2,
                        lineWidth: Metric.hairline
                    )
            )
            .fixedSize()
    }
}

/// The checkbox beside every rule.
///
/// Drawn rather than taken from AppKit: the system checkbox is the single
/// clearest tell that a window is a stock utility, and it will not take the
/// accent colour or the fifteen point size the design asks for.
struct CheckBox: View {
    let isOn: Bool
    var isEnabled = true

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isOn && isEnabled ? Tone.acc : Tone.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        isOn && isEnabled ? Tone.acc : Tone.b2,
                        lineWidth: Metric.hairline
                    )
            )
            .overlay {
                if isOn {
                    Path { path in
                        path.move(to: CGPoint(x: 3.5, y: 7.5))
                        path.addLine(to: CGPoint(x: 6.3, y: 10.3))
                        path.addLine(to: CGPoint(x: 11.5, y: 4.8))
                    }
                    .stroke(
                        isEnabled ? Tone.onacc : Tone.b2,
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .frame(width: 15, height: 15)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The thirty by eighteen switch used throughout Settings.
struct SwitchPill: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Tone.acc : Tone.b2)
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Tone.onacc : Tone.bg)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.14), value: isOn)
    }
}

/// A switch with its label, as the Settings rows use it.
struct SwitchRow: View {
    let title: LocalizedStringResource
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(Face.text(12.5))
                    .foregroundStyle(Tone.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                SwitchPill(isOn: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(String(localized: title), isOn: $isOn)
        }
    }
}

/// The app's own icon, used as the mark beside the logotype.
///
/// Read from the running application rather than from the asset catalog by
/// name, so it is by definition the same image the Dock and Finder show; if
/// the icon is ever replaced there is nothing here to keep in step.
struct AppMark: View {
    var size: CGFloat = 22

    var body: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            // Only reachable before the bundle has an icon at all.
            Sawtooth(size: size)
        }
    }
}

/// The Tortu mark: a sawtooth, one spike and a settling tail.
struct Sawtooth: View {
    var size: CGFloat = 18
    var color: Color = Tone.acc

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 18
            var path = Path()
            let points: [CGPoint] = [
                CGPoint(x: 1, y: 13), CGPoint(x: 4, y: 13), CGPoint(x: 6, y: 4),
                CGPoint(x: 8, y: 14), CGPoint(x: 10, y: 9), CGPoint(x: 12, y: 12),
                CGPoint(x: 17, y: 12),
            ].map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            path.addLines(points)
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
