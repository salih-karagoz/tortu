import Foundation
import ScanCore

/// How fast a series is growing.
public struct GrowthRate: Sendable, Hashable {
    public let bytesPerDay: Double
    /// The span the rate was measured over.
    public let window: TimeInterval
    public let sampleCount: Int

    public var isGrowing: Bool { bytesPerDay > 0 }

    public var formattedPerDay: String {
        let magnitude = Int64(abs(bytesPerDay).rounded())
        let formatted = magnitude.formatted(.byteCount(style: .file))
        return bytesPerDay < 0 ? "−\(formatted)" : formatted
    }
}

/// Turns a run of measurements into the number no snapshot can give.
///
/// A single reading says the disk is full. A series says which tool filled it
/// and how soon it will happen again, which is the only part a person can act
/// on. The slope comes from least squares rather than from first-to-last,
/// because a cleanup in the middle of the window would otherwise read as a
/// shrinking category when it is in fact growing fast between cleanups.
public enum GrowthAnalysis {
    public static let minimumSamples = 3

    public static func rate(of series: Series) -> GrowthRate? {
        let samples = series.samples
        guard samples.count >= minimumSamples else { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }

        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0 else { return nil }

        // x in days since the first sample, y in bytes.
        let origin = first.timestamp
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for sample in samples {
            let x = sample.timestamp.timeIntervalSince(origin) / 86_400
            let y = Double(sample.bytes.rawValue)
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
        }
        let count = Double(samples.count)
        let denominator = count * sumXX - sumX * sumX
        guard abs(denominator) > .ulpOfOne else { return nil }

        return GrowthRate(
            bytesPerDay: (count * sumXY - sumX * sumY) / denominator,
            window: span,
            sampleCount: samples.count
        )
    }

    /// When free space would reach zero if the current rate held.
    ///
    /// `rate` here describes free space, so a negative slope is the one that
    /// runs out. A flat or rising series returns nothing rather than a date in
    /// the distant future, which would be a false precision.
    public static func projectedExhaustion(
        free: ByteCount,
        rate: GrowthRate,
        from now: Date
    ) -> Date? {
        guard rate.bytesPerDay < 0 else { return nil }
        let days = Double(free.rawValue) / -rate.bytesPerDay
        guard days.isFinite, days >= 0, days < 3_650 else { return nil }
        return now.addingTimeInterval(days * 86_400)
    }

    /// Series ordered by how fast they are growing, fastest first. This is the
    /// view that answers "what is eating the disk".
    public static func rankedByGrowth(_ series: [Series]) -> [(series: Series, rate: GrowthRate)] {
        series
            .compactMap { item in rate(of: item).map { (series: item, rate: $0) } }
            .filter(\.rate.isGrowing)
            .sorted { $0.rate.bytesPerDay > $1.rate.bytesPerDay }
    }
}
