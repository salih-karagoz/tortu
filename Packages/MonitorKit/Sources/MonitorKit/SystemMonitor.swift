import Foundation
import ScanCore

/// Everything the machine will say about itself at one moment.
///
/// A snapshot is a difference, not a photograph: nearly every figure in it
/// only exists because there was a previous reading to subtract. The first
/// snapshot after the monitor starts therefore carries no rates, and says so
/// through `isFirst` rather than filling the gap with noughts.
public struct SystemSnapshot: Sendable, Equatable {
    public var taken: Date
    /// Seconds since the previous snapshot; zero on the first.
    public var interval: TimeInterval
    public var isFirst: Bool

    public var cpu: CPULoad
    public var loadAverage: [Double]
    public var memory: MemoryReading?
    public var gpu: GPUReading
    public var disk: DiskReading?
    public var network: NetworkReading
    public var power: PowerReading

    public var processes: [ProcessReading]
    /// How many of `processes` exist but belong to another user, whose
    /// figures this application is not allowed to read. They are listed all
    /// the same: leaving them out would be a quieter lie than saying so.
    public var closedProcesses: Int

    public init(
        taken: Date = .now,
        interval: TimeInterval = 0,
        isFirst: Bool = false,
        cpu: CPULoad = .idleMachine,
        loadAverage: [Double] = [],
        memory: MemoryReading? = nil,
        gpu: GPUReading = GPUReading(),
        disk: DiskReading? = nil,
        network: NetworkReading = .silent,
        power: PowerReading = PowerReading(),
        processes: [ProcessReading] = [],
        closedProcesses: Int = 0
    ) {
        self.taken = taken
        self.interval = interval
        self.isFirst = isFirst
        self.cpu = cpu
        self.loadAverage = loadAverage
        self.memory = memory
        self.gpu = gpu
        self.disk = disk
        self.network = network
        self.power = power
        self.processes = processes
        self.closedProcesses = closedProcesses
    }

    /// Every process the kernel admitted to, readable or not.
    public var processCount: Int { processes.count }

    /// The ones whose figures could be read.
    public var openProcesses: Int { processes.count - closedProcesses }

    /// Threads, counted across the processes whose figures could be read.
    public var threadCount: Int {
        processes.reduce(0) { $0 + ($1.threads ?? 0) }
    }

    /// Disk traffic attributed to processes, which is a different measure
    /// from the drivers' own: it counts what applications asked for, cache
    /// hits included, rather than what reached the hardware.
    public var processBytesPerSecond: Double {
        processes.reduce(0) {
            $0 + ($1.bytesReadPerSecond ?? 0) + ($1.bytesWrittenPerSecond ?? 0)
        }
    }

    public var wakeupsPerSecond: Double {
        processes.reduce(0) { $0 + ($1.wakeupsPerSecond ?? 0) }
    }
}

/// Takes the readings and keeps the previous round, which is the only way
/// any of them become rates.
///
/// An actor because it is stateful and must never be read from two places at
/// once, and because every one of these calls is a syscall that has no
/// business on the main thread while a window is being drawn.
public actor SystemMonitor {
    public let facts: MachineFacts

    private let cpuSampler = CPUSampler()
    private let memorySampler: MemorySampler
    private let processSampler = ProcessSampler()
    private let diskSampler = DiskSampler()
    private let networkSampler = NetworkSampler()
    private let powerSampler = PowerSampler()
    private let gpuSampler = GPUSampler()

    private var previousTicks: CPUTicks?
    private var previousProcesses: [pid_t: ProcessFacts] = [:]
    private var previousDisk: DiskCounters?
    private var network = NetworkAccumulator()
    private var previousTaken: Date?

    public init(facts: MachineFacts = .current()) {
        self.facts = facts
        memorySampler = MemorySampler(pageSize: facts.pageSize)
    }

    /// Forgets the previous round.
    ///
    /// Called when the screen comes back after being away: the counters kept
    /// climbing while nothing was watching, and a rate measured across that
    /// gap would be an average over minutes presented as a reading for now.
    public func reset() {
        previousTicks = nil
        previousProcesses = [:]
        previousDisk = nil
        network.reset()
        previousTaken = nil
    }

    /// One round of readings.
    ///
    /// `includeProcesses` is the expensive half — three syscalls for each of
    /// seven hundred processes — so a screen that is only drawing a graph can
    /// leave it out.
    public func take(includeProcesses: Bool = true, now: Date = .now) -> SystemSnapshot {
        let interval = previousTaken.map { now.timeIntervalSince($0) } ?? 0
        let isFirst = previousTaken == nil

        var snapshot = SystemSnapshot(
            taken: now,
            interval: interval,
            isFirst: isFirst,
            loadAverage: cpuSampler.loadAverage(),
            memory: memorySampler.sample(),
            gpu: gpuSampler.sample(),
            power: powerSampler.sample()
        )

        if let ticks = cpuSampler.sample(now: now) {
            if let previousTicks, let load = CPULoad(from: previousTicks, to: ticks) {
                snapshot.cpu = load
            }
            previousTicks = ticks
        }

        if let counters = diskSampler.sample(now: now) {
            if let previousDisk, let reading = DiskReading(from: previousDisk, to: counters) {
                snapshot.disk = reading
            } else {
                snapshot.disk = DiskReading(
                    totalRead: ByteCount(Int64(clamping: counters.bytesRead)),
                    totalWritten: ByteCount(Int64(clamping: counters.bytesWritten))
                )
            }
            previousDisk = counters
        }

        snapshot.network = network.reading(
            from: networkSampler.sample(), interval: interval
        )

        if includeProcesses {
            let facts = processSampler.sample()
            snapshot.processes = ProcessDelta.readings(
                from: previousProcesses, to: facts, interval: interval, now: now
            )
            snapshot.closedProcesses = facts.count { !$0.isReadable }
            previousProcesses = Dictionary(
                facts.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first }
            )
        }

        previousTaken = now
        return snapshot
    }
}
