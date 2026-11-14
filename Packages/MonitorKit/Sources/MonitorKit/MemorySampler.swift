import Darwin
import Foundation
import ScanCore

/// How the machine's memory is spoken for, right now.
///
/// The split is the one macOS itself reports rather than a tidier invention:
/// what applications hold, what is wired down and cannot be moved, and what
/// the compressor is holding in less space than it was asked for. `used` is
/// the sum of those three, which is the figure Activity Monitor calls Memory
/// Used — so that two instruments measuring the same machine agree.
public struct MemoryReading: Sendable, Equatable {
    public var total: ByteCount
    /// What applications hold, less what they have marked as discardable.
    public var application: ByteCount
    public var wired: ByteCount
    public var compressed: ByteCount
    /// File-backed pages the kernel is keeping in case they are wanted
    /// again. This is not a loss: it is returned the moment anything needs it.
    public var cached: ByteCount
    public var free: ByteCount
    public var swapTotal: ByteCount
    public var swapUsed: ByteCount
    public var pressure: MemoryPressure
    /// How many pages the compressor has taken in and handed back since the
    /// machine started. The pair says whether compression is merely holding
    /// or actually thrashing.
    public var compressions: UInt64
    public var decompressions: UInt64

    public init(
        total: ByteCount,
        application: ByteCount,
        wired: ByteCount,
        compressed: ByteCount,
        cached: ByteCount,
        free: ByteCount,
        swapTotal: ByteCount,
        swapUsed: ByteCount,
        pressure: MemoryPressure,
        compressions: UInt64 = 0,
        decompressions: UInt64 = 0
    ) {
        self.total = total
        self.application = application
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.compressions = compressions
        self.decompressions = decompressions
    }

    public var used: ByteCount { application + wired + compressed }

    public var usedFraction: Double {
        guard total.rawValue > 0 else { return 0 }
        return min(max(Double(used.rawValue) / Double(total.rawValue), 0), 1)
    }

    public var swapFraction: Double {
        guard swapTotal.rawValue > 0 else { return 0 }
        return min(max(Double(swapUsed.rawValue) / Double(swapTotal.rawValue), 0), 1)
    }
}

/// The kernel's own verdict on how tight memory is.
///
/// Taken from `kern.memorystatus_vm_pressure_level` rather than worked out
/// from a ratio: the kernel is the thing that acts on pressure, so its answer
/// is the one worth showing.
public enum MemoryPressure: Int, Sendable, Equatable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4
    case unknown = 0

    init(level: Int32) {
        self = MemoryPressure(rawValue: Int(level)) ?? .unknown
    }
}

public struct MemorySampler: Sendable {
    private let pageSize: Int

    public init(pageSize: Int) {
        self.pageSize = pageSize > 0 ? pageSize : 4096
    }

    public func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        func bytes(_ pages: UInt32) -> ByteCount {
            ByteCount(Int64(pages) * Int64(pageSize))
        }
        func bytes(_ pages: UInt64) -> ByteCount {
            ByteCount(Int64(clamping: pages) * Int64(pageSize))
        }

        // Purgeable pages are inside the internal count but belong to nobody
        // in particular: the kernel may drop them without asking. Counting
        // them as application memory overstates every machine by a little.
        let applicationPages = stats.internal_page_count >= stats.purgeable_count
            ? stats.internal_page_count - stats.purgeable_count
            : 0
        let freePages = stats.free_count >= stats.speculative_count
            ? stats.free_count - stats.speculative_count
            : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let hasPressure = sysctlbyname(
            "kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0
        ) == 0

        return MemoryReading(
            total: ByteCount(Int64(ProcessInfo.processInfo.physicalMemory)),
            application: bytes(applicationPages),
            wired: bytes(stats.wire_count),
            compressed: bytes(stats.compressor_page_count),
            cached: bytes(stats.external_page_count + stats.purgeable_count),
            free: bytes(freePages),
            swapTotal: ByteCount(Int64(clamping: hasSwap ? swap.xsu_total : 0)),
            swapUsed: ByteCount(Int64(clamping: hasSwap ? swap.xsu_used : 0)),
            pressure: hasPressure ? MemoryPressure(level: level) : .unknown,
            compressions: stats.compressions,
            decompressions: stats.decompressions
        )
    }
}
