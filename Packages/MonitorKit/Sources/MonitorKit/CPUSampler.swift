import Darwin
import Foundation

/// The kernel's running tick counters, per core.
///
/// These only ever climb, so a single reading says nothing at all. What is
/// worth showing is the difference between two of them, which is why the
/// reading and the load it implies are two different types here: one is
/// measured, the other is derived, and the derivation needs two measurements.
public struct CPUTicks: Sendable, Equatable {
    public struct Core: Sendable, Equatable {
        public var user: UInt64
        public var system: UInt64
        public var idle: UInt64
        public var nice: UInt64

        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }

        var total: UInt64 { user &+ system &+ idle &+ nice }
    }

    public var cores: [Core]
    public var taken: Date

    public init(cores: [Core], taken: Date) {
        self.cores = cores
        self.taken = taken
    }
}

/// How busy the processor was between two readings.
///
/// Every figure is a fraction of one, of the whole machine; `cores` holds the
/// same fraction for each core on its own. Nothing here is a percentage until
/// the screen makes it one.
public struct CPULoad: Sendable, Equatable {
    public var user: Double
    public var system: Double
    public var nice: Double
    public var idle: Double
    public var cores: [Double]

    public init(user: Double, system: Double, nice: Double, idle: Double, cores: [Double]) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
        self.cores = cores
    }

    public static let idleMachine = CPULoad(user: 0, system: 0, nice: 0, idle: 1, cores: [])

    public var busy: Double { min(max(user + system + nice, 0), 1) }

    /// The load between two readings.
    ///
    /// Returns nil when the two readings cannot be compared — a different
    /// number of cores, or no ticks at all between them — rather than
    /// dividing by zero and reporting a confident nought.
    public init?(from first: CPUTicks, to second: CPUTicks) {
        guard first.cores.count == second.cores.count, !first.cores.isEmpty else { return nil }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var nice: UInt64 = 0
        var idle: UInt64 = 0
        var total: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(second.cores.count)

        for (before, after) in zip(first.cores, second.cores) {
            // The counters are unsigned and monotonic, so a wrap or a core
            // coming back online shows up as a negative difference. Clamping
            // at nought drops that one interval rather than printing a spike.
            let coreUser = after.user &- before.user
            let coreSystem = after.system &- before.system
            let coreNice = after.nice &- before.nice
            let coreIdle = after.idle &- before.idle
            let coreTotal = after.total &- before.total
            guard after.total >= before.total, coreTotal > 0 else {
                perCore.append(0)
                continue
            }
            user &+= coreUser
            system &+= coreSystem
            nice &+= coreNice
            idle &+= coreIdle
            total &+= coreTotal
            perCore.append(Double(coreUser &+ coreSystem &+ coreNice) / Double(coreTotal))
        }

        guard total > 0 else { return nil }
        self.init(
            user: Double(user) / Double(total),
            system: Double(system) / Double(total),
            nice: Double(nice) / Double(total),
            idle: Double(idle) / Double(total),
            cores: perCore
        )
    }
}

/// Reads the per-core tick counters.
public struct CPUSampler: Sendable {
    public init() {}

    public func sample(now: Date = .now) -> CPUTicks? {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count
        ) == KERN_SUCCESS, let info else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)
            )
        }

        let ticks = UnsafeBufferPointer(start: info, count: Int(count))
        let states = Int(CPU_STATE_MAX)
        var result: [CPUTicks.Core] = []
        result.reserveCapacity(Int(cores))
        for core in 0 ..< Int(cores) {
            let base = core * states
            guard base + states <= ticks.count else { break }
            result.append(CPUTicks.Core(
                user: UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]))
            ))
        }
        guard !result.isEmpty else { return nil }
        return CPUTicks(cores: result, taken: now)
    }

    /// The one, five and fifteen minute load averages.
    public func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return [] }
        return values
    }
}
