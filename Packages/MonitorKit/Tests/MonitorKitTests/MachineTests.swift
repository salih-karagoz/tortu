import Darwin
import Foundation
import ScanCore
import Testing
@testable import MonitorKit

/// Readings taken from the machine the tests are running on.
///
/// These cannot assert a value, only that the shape of what comes back is
/// possible: a fraction between nought and one, a total that is not zero, a
/// process list that contains the test process itself. That is enough to
/// catch the failures that matter here, which are a sampler returning nothing
/// and a unit conversion that is out by a factor.
@Suite("The machine")
struct MachineTests {
    @Test("The machine describes itself")
    func facts() {
        let facts = MachineFacts.current()
        #expect(facts.logicalCores > 0)
        #expect(facts.physicalMemory.rawValue > 0)
        #expect(facts.pageSize >= 4096)
        #expect(facts.uptime > 0)
        // A split into two levels must add up to the whole, or it is not a
        // split and must not be printed as one.
        if facts.performanceCores > 0 || facts.efficiencyCores > 0 {
            #expect(facts.performanceCores + facts.efficiencyCores == facts.logicalCores)
        }
    }

    /// The conversion this package most needs to be right about.
    ///
    /// `proc_pidinfo` reports processor time in mach units, not nanoseconds,
    /// and reading it as nanoseconds under-reports every process by around
    /// forty times on Apple silicon. `getrusage` reports the same quantity
    /// for this process in plain seconds and microseconds, so the two must
    /// agree.
    @Test("Processor time converts to the same seconds the C library reports")
    func processorTimeUnits() throws {
        // Something to actually measure, so neither figure is zero.
        var sink = 0.0
        for index in 1 ... 4_000_000 { sink += Double(index).squareRoot() }
        #expect(sink > 0)

        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let fromLibrary = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6

        var task = proc_taskinfo()
        let read = proc_pidinfo(
            getpid(), PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)
        )
        #expect(read > 0)
        let fromKernel = MachClock.seconds(task.pti_total_user &+ task.pti_total_system)

        #expect(fromLibrary > 0.01)
        #expect(abs(fromKernel - fromLibrary) < max(fromLibrary * 0.25, 0.05))
    }

    @Test("The processor reports a load between nothing and everything")
    func cpu() async throws {
        let sampler = CPUSampler()
        let first = try #require(sampler.sample())
        #expect(first.cores.count == MachineFacts.current().logicalCores)
        try await Task.sleep(for: .milliseconds(250))
        let second = try #require(sampler.sample())
        let load = try #require(CPULoad(from: first, to: second))
        #expect(load.busy >= 0 && load.busy <= 1)
        #expect(abs(load.user + load.system + load.nice + load.idle - 1) < 0.001)
        #expect(load.cores.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
        #expect(sampler.loadAverage().count == 3)
    }

    @Test("Memory adds up to about what the machine has")
    func memory() throws {
        let facts = MachineFacts.current()
        let reading = try #require(MemorySampler(pageSize: facts.pageSize).sample())
        #expect(reading.total.rawValue > 0)
        #expect(reading.used.rawValue > 0)
        #expect(reading.usedFraction > 0 && reading.usedFraction <= 1)
        // Some pages are spoken for by firmware and never appear in the
        // statistics, so the parts come to a little under the whole. Far
        // under, or over, means the accounting is wrong.
        let parts = reading.used + reading.cached + reading.free
        let ratio = Double(parts.rawValue) / Double(reading.total.rawValue)
        #expect(ratio > 0.8 && ratio <= 1.05)
    }

    @Test("The process list contains this very process")
    func processes() throws {
        let facts = ProcessSampler().sample()
        #expect(facts.count > 10)
        let mine = try #require(facts.first { $0.pid == getpid() })
        #expect(mine.isReadable)
        #expect(mine.threads ?? 0 > 0)
        #expect(mine.footprint?.rawValue ?? 0 > 0)
        #expect(mine.path?.isEmpty == false)
        #expect(mine.uid == getuid())
        // Processes belonging to other users are listed without their
        // figures. That is the expected state for an unprivileged build, and
        // the screen reports the shortfall rather than hiding it.
        #expect(facts.contains { !$0.isReadable } || getuid() == 0)
    }

    @Test("Disk and network counters only climb")
    func counters() async throws {
        let disk = DiskSampler()
        if let first = disk.sample() {
            try await Task.sleep(for: .milliseconds(200))
            let second = try #require(disk.sample())
            #expect(second.bytesRead >= first.bytesRead)
            #expect(second.bytesWritten >= first.bytesWritten)
            let reading = try #require(DiskReading(from: first, to: second))
            #expect(reading.readPerSecond >= 0)
        }

        let network = NetworkSampler()
        let interfaces = network.sample()
        #expect(!interfaces.isEmpty)
        #expect(interfaces.contains { $0.kind == .loopback })
    }

    @Test("A snapshot carries no rates until there is something to compare")
    func firstSnapshot() async throws {
        let monitor = SystemMonitor()
        let first = await monitor.take()
        #expect(first.isFirst)
        #expect(first.interval == 0)
        #expect(first.memory != nil)
        #expect(first.processCount > 10)

        try await Task.sleep(for: .milliseconds(300))
        let second = await monitor.take()
        #expect(!second.isFirst)
        #expect(second.interval > 0.2)
        #expect(second.cpu.busy >= 0)
        #expect(second.threadCount > 0)
        // Resetting makes the next reading a first one again, because the
        // counters kept climbing while nothing was watching.
        await monitor.reset()
        #expect(await monitor.take().isFirst)
    }

    @Test("Power and graphics report what they have, and nothing where they have none")
    func powerAndGraphics() {
        let power = PowerSampler().sample()
        if let charge = power.charge { #expect(charge >= 0 && charge <= 1) }
        if let watts = power.batteryWatts { #expect(watts > 0 && watts < 300) }
        if let health = power.health { #expect(health > 0 && health <= 1.5) }
        #expect(power.hasBattery || power.source != .battery)

        let gpu = GPUSampler().sample()
        if let utilisation = gpu.utilisation { #expect(utilisation >= 0 && utilisation <= 1) }
    }
}
