import Foundation
import IOKit
import ScanCore

/// The volume of traffic the storage drivers have carried since boot.
public struct DiskCounters: Sendable, Equatable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var reads: UInt64
    public var writes: UInt64
    public var taken: Date

    public init(
        bytesRead: UInt64 = 0,
        bytesWritten: UInt64 = 0,
        reads: UInt64 = 0,
        writes: UInt64 = 0,
        taken: Date = .now
    ) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.reads = reads
        self.writes = writes
        self.taken = taken
    }
}

/// What the disk is doing right now, and what it has done altogether.
public struct DiskReading: Sendable, Equatable {
    public var readPerSecond: Double
    public var writtenPerSecond: Double
    public var readsPerSecond: Double
    public var writesPerSecond: Double
    public var totalRead: ByteCount
    public var totalWritten: ByteCount

    public init(
        readPerSecond: Double = 0,
        writtenPerSecond: Double = 0,
        readsPerSecond: Double = 0,
        writesPerSecond: Double = 0,
        totalRead: ByteCount = .zero,
        totalWritten: ByteCount = .zero
    ) {
        self.readPerSecond = readPerSecond
        self.writtenPerSecond = writtenPerSecond
        self.readsPerSecond = readsPerSecond
        self.writesPerSecond = writesPerSecond
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }

    public init?(from first: DiskCounters, to second: DiskCounters) {
        let span = second.taken.timeIntervalSince(first.taken)
        guard span > 0 else { return nil }
        func rate(_ now: UInt64, _ then: UInt64) -> Double {
            now >= then ? Double(now - then) / span : 0
        }
        self.init(
            readPerSecond: rate(second.bytesRead, first.bytesRead),
            writtenPerSecond: rate(second.bytesWritten, first.bytesWritten),
            readsPerSecond: rate(second.reads, first.reads),
            writesPerSecond: rate(second.writes, first.writes),
            totalRead: ByteCount(Int64(clamping: second.bytesRead)),
            totalWritten: ByteCount(Int64(clamping: second.bytesWritten))
        )
    }
}

/// Reads the block storage drivers' own counters.
///
/// Every driver in the registry is added together, so an external disk shows
/// up in the figure the moment it is plugged in. This is traffic to the
/// hardware, not to the file system: a read served from the cache never
/// reaches here, which is why the number is lower than an application's own
/// accounting and is the right one to show for a disk.
public struct DiskSampler: Sendable {
    /// The registry's own key names. They are C macros in
    /// `IOBlockStorageDriver.h`, which is not exposed to Swift, so they are
    /// written out here rather than reached for through a bridging header.
    private enum Statistic {
        static let container = "Statistics"
        static let bytesRead = "Bytes (Read)"
        static let bytesWritten = "Bytes (Write)"
        static let reads = "Operations (Read)"
        static let writes = "Operations (Write)"
    }

    public init() {}

    public func sample(now: Date = .now) -> DiskCounters? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var counters = DiskCounters(taken: now)
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                let dictionary = properties?.takeRetainedValue() as? [String: Any],
                let statistics = dictionary[Statistic.container] as? [String: Any]
            else { continue }

            found = true
            func value(_ key: String) -> UInt64 {
                UInt64(clamping: (statistics[key] as? Int64) ?? 0)
            }
            counters.bytesRead &+= value(Statistic.bytesRead)
            counters.bytesWritten &+= value(Statistic.bytesWritten)
            counters.reads &+= value(Statistic.reads)
            counters.writes &+= value(Statistic.writes)
        }
        return found ? counters : nil
    }
}
