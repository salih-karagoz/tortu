import Darwin
import Foundation
import ScanCore

/// What the machine is, read once.
///
/// None of this changes while the app is running, so it is read at launch and
/// kept. The screen prints it under the live figures, because a percentage
/// means nothing without knowing how many cores it is a percentage of.
public struct MachineFacts: Sendable, Equatable {
    /// The model identifier, e.g. `Mac16,13`.
    public let model: String
    /// The processor's own name, e.g. `Apple M4`.
    public let chip: String
    public let logicalCores: Int
    /// Apple silicon splits its cores into two levels. Both are zero on a
    /// machine that has only one kind, and the screen then says nothing
    /// about them rather than inventing a split.
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let physicalMemory: ByteCount
    public let pageSize: Int
    public let bootTime: Date

    public init(
        model: String,
        chip: String,
        logicalCores: Int,
        performanceCores: Int,
        efficiencyCores: Int,
        physicalMemory: ByteCount,
        pageSize: Int,
        bootTime: Date
    ) {
        self.model = model
        self.chip = chip
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.physicalMemory = physicalMemory
        self.pageSize = pageSize
        self.bootTime = bootTime
    }

    public static func current() -> MachineFacts {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0)

        return MachineFacts(
            model: Sysctl.string("hw.model") ?? "",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "",
            logicalCores: Sysctl.integer("hw.logicalcpu") ?? ProcessInfo.processInfo
                .activeProcessorCount,
            performanceCores: Sysctl.integer("hw.perflevel0.logicalcpu") ?? 0,
            efficiencyCores: Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0,
            physicalMemory: ByteCount(Int64(ProcessInfo.processInfo.physicalMemory)),
            pageSize: size > 0 ? Int(size) : 4096,
            bootTime: Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        )
    }

    /// How long the machine has been up.
    public var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }
}

/// The two `sysctl` reads this package needs, wrapped so the ceremony lives
/// in one place rather than at every call site.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// Converts the kernel's own clock units into seconds.
///
/// `proc_pidinfo` and `proc_pid_rusage` report processor time in mach absolute
/// units, not in nanoseconds, whatever the field names suggest. On Apple
/// silicon one unit is 41⅔ nanoseconds, so reading the figure as nanoseconds
/// under-reports every process by a factor of forty — which is exactly the
/// kind of plausible, wrong number this application must not print.
public enum MachClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.denom == 0 { info = mach_timebase_info_data_t(numer: 1, denom: 1) }
        return info
    }()

    /// Mach absolute units as seconds.
    public static func seconds(_ units: UInt64) -> Double {
        Double(units) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
