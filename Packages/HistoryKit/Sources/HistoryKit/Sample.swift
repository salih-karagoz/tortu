import Foundation
import ScanCore

/// One measurement at one moment.
public struct Sample: Sendable, Hashable, Identifiable {
    public let timestamp: Date
    public let bytes: ByteCount

    public var id: Date { timestamp }

    public init(timestamp: Date, bytes: ByteCount) {
        self.timestamp = timestamp
        self.bytes = bytes
    }
}

/// A named run of samples, which is what a chart draws.
public struct Series: Sendable, Identifiable {
    public let id: String
    public let samples: [Sample]

    public init(id: String, samples: [Sample]) {
        self.id = id
        self.samples = samples.sorted { $0.timestamp < $1.timestamp }
    }

    public var latest: Sample? { samples.last }
    public var earliest: Sample? { samples.first }

    public var span: TimeInterval {
        guard let first = earliest, let last = latest else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    public func clipped(to window: TimeInterval, now: Date) -> Series {
        let cutoff = now.addingTimeInterval(-window)
        return Series(id: id, samples: samples.filter { $0.timestamp >= cutoff })
    }
}
