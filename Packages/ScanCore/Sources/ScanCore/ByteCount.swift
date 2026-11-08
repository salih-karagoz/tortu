import Foundation

/// A byte quantity, kept distinct from a plain integer so that a logical size
/// and an allocated size can never be mixed up by accident.
///
/// Tortu reports two different numbers for the same file and they routinely
/// disagree: `logical` is what the file claims to be, `allocated` is what the
/// volume actually gives back when the file is removed. Only the second one
/// is a promise we can keep.
public struct ByteCount: Sendable, Hashable, Comparable, Codable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static let zero = ByteCount(0)

    /// Builds a count from a block count and block size, the shape `stat` and
    /// `statfs` both hand back.
    public init(blocks: Int64, blockSize: Int64) {
        self.rawValue = blocks * blockSize
    }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func + (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(lhs.rawValue + rhs.rawValue)
    }

    public static func - (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(lhs.rawValue - rhs.rawValue)
    }

    public static func += (lhs: inout ByteCount, rhs: ByteCount) {
        lhs = lhs + rhs
    }

    /// Decimal units, matching what Finder and `df -h` show the user.
    public var formatted: String {
        rawValue.formatted(.byteCount(style: .file))
    }
}
