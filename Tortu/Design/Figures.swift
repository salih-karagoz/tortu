import Foundation
import ScanCore

/// Numbers, split into the part that is set in Space Grotesk and the unit
/// that is set beside it at a smaller size.
///
/// `ByteCount.formatted` produces one string, which is right for a log line
/// and wrong for this design: every size on screen is a large figure with a
/// small unit next to it, in a different weight and colour. So the two are
/// produced separately here, in decimal units, matching what Finder and
/// `df -h` show rather than the powers of two the kernel counts in.
enum Figure {
    struct Measure: Equatable {
        var value: String
        var unit: String

        var joined: String { "\(value) \(unit)" }
    }

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// A byte count as a figure and a unit, e.g. `27,4` and `GB`.
    ///
    /// Bytes and kilobytes are shown whole; from megabytes up, one decimal,
    /// which is the precision the design shows everywhere and about as far as
    /// a directory walk can honestly claim.
    /// `fractionDigits` overrides the default precision, for places such as
    /// a chart's gridline labels where a decimal is noise.
    static func bytes(_ count: ByteCount, fractionDigits: Int? = nil) -> Measure {
        let raw = Double(count.rawValue)
        let magnitude = abs(raw)
        guard magnitude >= 1000 else {
            return Measure(value: integer(raw), unit: units[0])
        }
        var scaled = magnitude
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        if raw < 0 { scaled = -scaled }
        let digits = fractionDigits ?? (index <= 1 ? 0 : 1)
        return Measure(value: decimal(scaled, digits: digits), unit: units[index])
    }

    /// A rate as a figure and a unit, e.g. `−1,2` and `GB / gün`.
    ///
    /// The sign is a real minus sign rather than a hyphen, because it sits in
    /// a column of Space Grotesk figures where a hyphen is visibly too short.
    static func perDay(_ bytesPerDay: Double) -> Measure {
        let measure = bytes(ByteCount(Int64(bytesPerDay.rounded())))
        let signed = bytesPerDay < 0 && !measure.value.hasPrefix("−")
            ? "−" + measure.value.replacingOccurrences(of: "-", with: "")
            : measure.value.replacingOccurrences(of: "-", with: "−")
        return Measure(
            value: signed,
            unit: "\(measure.unit) / \(String(localized: "unit.day"))"
        )
    }

    /// Gigabytes per day as a bare figure, for the growth bars, which already
    /// carry their unit in the section heading.
    static func gigabytesPerDay(_ bytesPerDay: Double) -> String {
        decimal(bytesPerDay / 1_000_000_000, digits: 2)
    }

    /// A size for a chart's axis: one decimal, but only when it is not zero,
    /// so a run of labels reads `2,5 GB · 5 GB · 7,5 GB` rather than
    /// `2,5 GB · 5,0 GB · 7,5 GB`.
    static func axisBytes(_ count: ByteCount) -> String {
        let measure = bytes(count)
        let zeroDecimal = Locale.current.decimalSeparator.map { $0 + "0" } ?? ".0"
        guard measure.value.hasSuffix(zeroDecimal) else { return measure.joined }
        return String(measure.value.dropLast(zeroDecimal.count)) + " " + measure.unit
    }

    /// A whole number with the locale's grouping, e.g. `1.284.902`.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A percentage as a whole number, written the way the locale writes it.
    ///
    /// The sign is replaced with a true minus, because these sit in columns
    /// of Space Grotesk figures where a hyphen is visibly too short.
    static func percent(_ fraction: Double) -> String {
        fraction
            .formatted(.percent.precision(.fractionLength(0)))
            .replacingOccurrences(of: "-", with: "−")
    }

    private static func integer(_ value: Double) -> String {
        Int64(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }
}
