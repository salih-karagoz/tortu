import CoreText
import Foundation
import SwiftUI

/// Bundled type.
///
/// Two variable faces ship with the app under the SIL Open Font License, the
/// licences beside them in `Resources/Fonts`:
///
/// - **Space Grotesk** for figures and headings. Its digits are the reason it
///   is here; a disk tool is a column of numbers.
/// - **Inter** for everything that is read as words.
///
/// Both are variable fonts, which is why weights are asked for as numbers
/// rather than as `Font.Weight`. The design calls for Space Grotesk 600, and
/// 600 is not one of the named instances in the file — only Light, Regular,
/// Medium and Bold are. Setting the `wght` axis directly gets the weight the
/// design asked for instead of the nearest one that happens to be named.
///
/// Every face is built with `tnum` switched on. Without it these fonts set
/// `111` almost a third narrower than `000`, and a column of sizes stops
/// lining up.
enum Face {
    /// Space Grotesk. Figures, headings, the logotype.
    static let displayFamily = "Space Grotesk"
    /// Inter. Running text, labels, table bodies.
    static let textFamily = "Inter"

    private static let displayPostScript = "SpaceGrotesk-Light"
    private static let textPostScript = "Inter-Regular"

    private static let weightAxis = 0x7767_6874 // 'wght'

    @MainActor private static var registered = false
    @MainActor private static var cache: [Key: Font] = [:]
    @MainActor private static var missing: Set<String> = []

    private struct Key: Hashable {
        let postScript: String
        let size: CGFloat
        let weight: Double
    }

    /// Registers the bundled faces with Core Text.
    ///
    /// Called once, before the first view is laid out. Doing it in code rather
    /// than through `ATSApplicationFontsPath` keeps it independent of how the
    /// resources end up arranged inside the bundle, and makes a missing file
    /// visible here instead of as a silent fallback to the system font.
    @MainActor
    static func register() {
        guard !registered else { return }
        registered = true
        for name in ["SpaceGrotesk", "Inter"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                missing.insert(name)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                missing.insert(name)
                error?.release()
            }
        }
    }

    /// Space Grotesk at an exact weight on the `wght` axis.
    @MainActor
    static func display(_ size: CGFloat, _ weight: Double = 600) -> Font {
        resolve(
            postScript: displayPostScript, family: displayFamily,
            size: size, weight: weight, fallbackDesign: .rounded
        )
    }

    /// Inter at an exact weight on the `wght` axis.
    @MainActor
    static func text(_ size: CGFloat, _ weight: Double = 400) -> Font {
        resolve(
            postScript: textPostScript, family: textFamily,
            size: size, weight: weight, fallbackDesign: .default
        )
    }

    @MainActor
    private static func resolve(
        postScript: String,
        family: String,
        size: CGFloat,
        weight: Double,
        fallbackDesign: Font.Design
    ) -> Font {
        let key = Key(postScript: postScript, size: size, weight: weight)
        if let cached = cache[key] { return cached }

        let font = build(postScript: postScript, family: family, size: size, weight: weight)
            ?? .system(size: size, weight: systemWeight(weight), design: fallbackDesign)
        cache[key] = font
        return font
    }

    /// Returns nil when the bundled face did not resolve, so the caller can
    /// fall back. Core Text answers a font matching request it cannot satisfy
    /// with a substitute rather than with nothing, so the family name of what
    /// came back is checked against the family that was asked for.
    @MainActor
    private static func build(
        postScript: String,
        family: String,
        size: CGFloat,
        weight: Double
    ) -> Font? {
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: postScript,
            kCTFontVariationAttribute: [weightAxis: weight],
            kCTFontFeatureSettingsAttribute: [[
                kCTFontOpenTypeFeatureTag: "tnum",
                kCTFontOpenTypeFeatureValue: 1,
            ]],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        guard CTFontCopyFamilyName(ctFont) as String == family else { return nil }
        return Font(ctFont)
    }

    private static func systemWeight(_ weight: Double) -> Font.Weight {
        switch weight {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }
}

extension String {
    /// Uppercases for display in the user's language.
    ///
    /// `.textCase(.uppercase)` and plain `uppercased()` are locale
    /// independent, which turns Turkish `i` into `I` rather than `İ`. The
    /// design puts uppercase labels on every section, so that would be
    /// visible on most screens of the app.
    var displayUppercase: String { uppercased(with: .current) }
}
