import SwiftUI

/// The design's colour tokens.
///
/// Every value lives once, in `Resources/Assets.xcassets/Tone`, with a light
/// and a dark variant. Reading them through the asset catalog rather than
/// through a Swift table is what makes the app follow the system appearance
/// without a single `colorScheme` check: AppKit resolves the right variant at
/// draw time, including inside the menu bar panel, which is a separate window
/// and would otherwise have to be told about the theme by hand.
///
/// Names are the design's own (`sec`, `b2`, `acct`), kept rather than
/// improved, so that a value in `DESIGN.md` can be found here by searching for
/// the same word.
enum Tone {
    /// Window ground.
    static let bg = Color("Tone/bg")
    /// Primary text, and filled bars that are not the subject.
    static let ink = Color("Tone/ink")
    /// Secondary text.
    static let sec = Color("Tone/sec")
    /// Labels and small notes. Holds 4.5:1 against `bg`.
    static let muted = Color("Tone/muted")
    /// Hairline borders and dividers.
    static let line = Color("Tone/line")
    /// Selected navigation ground, empty bar track.
    static let soft = Color("Tone/soft")
    /// Ground of a locked row.
    static let softer = Color("Tone/softer")
    /// Button border, and the dashed "estimated" bar.
    static let b2 = Color("Tone/b2")
    /// The one accent: waterline, selected row border, primary button.
    static let acc = Color("Tone/acc")
    /// The accent as text. A darker tint, because the accent itself does not
    /// hold contrast at 11 px.
    static let acct = Color("Tone/acct")
    /// Fill of a selected row.
    static let tint = Color("Tone/tint")
    /// Area fill under the waterline.
    static let area = Color("Tone/area")
    /// Shadow under the floating action bar.
    static let shadow = Color("Tone/shadow")
    /// Text on top of the accent.
    static let onacc = Color("Tone/onacc")

    /// Traffic lights, for the places the app draws its own window furniture.
    enum Traffic {
        static let close = Color(red: 0xEC / 255, green: 0x6A / 255, blue: 0x5E / 255)
        static let minimise = Color(red: 0xF4 / 255, green: 0xBF / 255, blue: 0x4F / 255)
        static let zoom = Color(red: 0x61 / 255, green: 0xC5 / 255, blue: 0x54 / 255)
    }

    /// Steps of ink used where several series share one chart.
    ///
    /// The design forbids carrying category identity in hue, so a stacked
    /// chart separates its bands by lightness alone and names each one with a
    /// label. Index 0 is reserved for the featured series, which is drawn in
    /// `acc` instead.
    static func step(_ index: Int) -> Color {
        let opacities: [Double] = [0.92, 0.72, 0.56, 0.42, 0.30, 0.21, 0.14]
        return ink.opacity(opacities[min(max(index, 0), opacities.count - 1)])
    }
}

/// Measurements the design fixes once.
enum Metric {
    static let boxRadius: CGFloat = 8
    static let panelRadius: CGFloat = 14
    static let controlRadius: CGFloat = 6
    static let segmentRadius: CGFloat = 4
    static let hairline: CGFloat = 1

    static let sidebarWidth: CGFloat = 200
    static let navRowHeight: CGFloat = 36
    static let buttonHeight: CGFloat = 34
    static let segmentHeight: CGFloat = 28

    static let windowWidth: CGFloat = 980
    static let windowHeight: CGFloat = 640
}
