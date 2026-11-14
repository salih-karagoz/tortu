import Foundation
import ScanCore
import Testing
@testable import MonitorKit

/// The arithmetic that turns two climbing counters into a rate.
///
/// Every one of these is a case where getting it wrong produces a plausible
/// number rather than an obvious failure, which is the only kind of bug that
/// matters in an instrument.
@Suite("Deltas")
struct DeltaTests {
    private func ticks(_ values: [(UInt64, UInt64, UInt64)], at seconds: TimeInterval) -> CPUTicks {
        CPUTicks(
            cores: values.map {
                CPUTicks.Core(user: $0.0, system: $0.1, idle: $0.2, nice: 0)
            },
            taken: Date(timeIntervalSinceReferenceDate: seconds)
        )
    }

    @Test("Half busy reads as half busy")
    func cpuHalf() throws {
        let load = try #require(CPULoad(
            from: ticks([(0, 0, 0)], at: 0),
            to: ticks([(30, 20, 50)], at: 1)
        ))
        #expect(abs(load.user - 0.3) < 0.0001)
        #expect(abs(load.system - 0.2) < 0.0001)
        #expect(abs(load.idle - 0.5) < 0.0001)
        #expect(abs(load.busy - 0.5) < 0.0001)
    }

    @Test("Each core is measured on its own")
    func cpuPerCore() throws {
        let load = try #require(CPULoad(
            from: ticks([(0, 0, 0), (0, 0, 0)], at: 0),
            to: ticks([(100, 0, 0), (0, 0, 100)], at: 1)
        ))
        #expect(load.cores.count == 2)
        #expect(abs(load.cores[0] - 1) < 0.0001)
        #expect(abs(load.cores[1]) < 0.0001)
        // The machine as a whole is half busy, not fully.
        #expect(abs(load.busy - 0.5) < 0.0001)
    }

    @Test("Nothing between two readings is not a load of nought")
    func cpuNoTicks() {
        #expect(CPULoad(from: ticks([(5, 5, 5)], at: 0), to: ticks([(5, 5, 5)], at: 1)) == nil)
    }

    @Test("A core count that changed cannot be compared")
    func cpuCoreMismatch() {
        #expect(CPULoad(from: ticks([(0, 0, 0)], at: 0), to: ticks([(1, 1, 1), (1, 1, 1)], at: 1)) == nil)
    }

    @Test("A counter that went backwards drops that core instead of spiking")
    func cpuBackwards() throws {
        let load = try #require(CPULoad(
            from: ticks([(100, 0, 100), (0, 0, 0)], at: 0),
            to: ticks([(0, 0, 0), (50, 0, 50)], at: 1)
        ))
        #expect(load.cores[0] == 0)
        #expect(abs(load.cores[1] - 0.5) < 0.0001)
    }

    // MARK: Processes

    private func process(
        _ pid: pid_t,
        cpuUnits: UInt64?,
        wakeups: UInt64? = nil,
        read: UInt64? = nil,
        started: TimeInterval = 0
    ) -> ProcessFacts {
        ProcessFacts(
            pid: pid,
            name: "test",
            started: Date(timeIntervalSinceReferenceDate: started),
            cpuUnits: cpuUnits,
            threads: 1,
            idleWakeups: wakeups,
            bytesRead: read
        )
    }

    @Test("A process busy for half the interval reads as half a core")
    func processHalfCore() throws {
        let oneSecond = UInt64(1 / MachClock.seconds(1))
        let readings = ProcessDelta.readings(
            from: [1: process(1, cpuUnits: 0)],
            to: [process(1, cpuUnits: oneSecond / 2)],
            interval: 1
        )
        let cpu = try #require(readings.first?.cpu)
        #expect(abs(cpu - 0.5) < 0.01)
    }

    @Test("An unreadable process reports nothing rather than nought")
    func processClosed() {
        let readings = ProcessDelta.readings(
            from: [:], to: [process(1, cpuUnits: nil)], interval: 1
        )
        #expect(readings.count == 1)
        #expect(readings[0].cpu == nil)
        #expect(readings[0].isReadable == false)
    }

    @Test("A process seen for the first time is measured over its own life")
    func processFirstSight() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let twentySeconds = UInt64(20 / MachClock.seconds(1))
        let readings = ProcessDelta.readings(
            from: [:],
            to: [process(1, cpuUnits: twentySeconds, started: 0)],
            interval: 1,
            now: now
        )
        // Twenty seconds of processor time over a hundred seconds alive.
        let cpu = try #require(readings.first?.cpu)
        #expect(abs(cpu - 0.2) < 0.01)
    }

    @Test("A reused pid is not reported as a negative rate")
    func processReusedPid() {
        let before = process(1, cpuUnits: 1_000_000, started: 0)
        let after = process(1, cpuUnits: 10, started: 50)
        let readings = ProcessDelta.readings(from: [1: before], to: [after], interval: 1, now: Date(timeIntervalSinceReferenceDate: 60))
        // Different start time, so it is a different process and is measured
        // over its own ten seconds rather than against the old counter.
        #expect((readings.first?.cpu ?? -1) >= 0)
    }

    @Test("Wakeups and disk bytes become per-second rates")
    func processRates() throws {
        let readings = ProcessDelta.readings(
            from: [1: process(1, cpuUnits: 0, wakeups: 100, read: 1_000)],
            to: [process(1, cpuUnits: 0, wakeups: 400, read: 5_000)],
            interval: 2
        )
        let reading = try #require(readings.first)
        #expect(reading.wakeupsPerSecond == 150)
        #expect(reading.bytesReadPerSecond == 2_000)
    }

    // MARK: Disk

    @Test("Disk counters become bytes a second")
    func diskRate() throws {
        let first = DiskCounters(
            bytesRead: 1_000, bytesWritten: 500, reads: 10, writes: 5,
            taken: Date(timeIntervalSinceReferenceDate: 0)
        )
        let second = DiskCounters(
            bytesRead: 5_000, bytesWritten: 2_500, reads: 30, writes: 15,
            taken: Date(timeIntervalSinceReferenceDate: 2)
        )
        let reading = try #require(DiskReading(from: first, to: second))
        #expect(reading.readPerSecond == 2_000)
        #expect(reading.writtenPerSecond == 1_000)
        #expect(reading.readsPerSecond == 10)
        #expect(reading.totalRead == ByteCount(5_000))
    }

    @Test("Two readings taken at the same moment are not a rate")
    func diskNoInterval() {
        let counters = DiskCounters(bytesRead: 10, taken: Date(timeIntervalSinceReferenceDate: 1))
        #expect(DiskReading(from: counters, to: counters) == nil)
    }

    // MARK: Network

    @Test("Loopback is counted but kept out of the machine's traffic")
    func networkExcludesLoopback() {
        var accumulator = NetworkAccumulator()
        _ = accumulator.reading(from: [
            InterfaceCounters(name: "en0", kind: .physical, bytesIn: 0, bytesOut: 0),
            InterfaceCounters(name: "lo0", kind: .loopback, bytesIn: 0, bytesOut: 0),
        ], interval: 0)
        let reading = accumulator.reading(from: [
            InterfaceCounters(name: "en0", kind: .physical, bytesIn: 2_000, bytesOut: 1_000),
            InterfaceCounters(name: "lo0", kind: .loopback, bytesIn: 9_000_000, bytesOut: 9_000_000),
        ], interval: 2)
        #expect(reading.inPerSecond == 1_000)
        #expect(reading.outPerSecond == 500)
        #expect(reading.interfaces.count == 2)
        #expect(reading.sessionIn == ByteCount(2_000))
        // Loopback is the busiest interface on most machines and still does
        // not count towards what left it.
        #expect(reading.active.first?.name == "lo0")
    }

    @Test("A counter that wrapped past four gigabytes is still a rate")
    func networkWrap() {
        var accumulator = NetworkAccumulator()
        let justBelow = UInt32.max - 999
        _ = accumulator.reading(
            from: [InterfaceCounters(name: "en0", kind: .physical, bytesIn: justBelow, bytesOut: 0)],
            interval: 0
        )
        // A thousand bytes to the top of the counter, a thousand past it.
        let reading = accumulator.reading(
            from: [InterfaceCounters(name: "en0", kind: .physical, bytesIn: 1_000, bytesOut: 0)],
            interval: 1
        )
        #expect(reading.inPerSecond == 2_000)
        #expect(reading.sessionIn == ByteCount(2_000))
        #expect(NetworkAccumulator.passed(1_000, since: justBelow) == 2_000)
    }

    @Test("A running total keeps adding up across readings")
    func networkSession() {
        var accumulator = NetworkAccumulator()
        _ = accumulator.reading(
            from: [InterfaceCounters(name: "en0", kind: .physical, bytesIn: 0, bytesOut: 0)],
            interval: 0
        )
        for step in 1 ... 3 {
            let reading = accumulator.reading(
                from: [InterfaceCounters(
                    name: "en0", kind: .physical, bytesIn: UInt32(step * 500), bytesOut: 0
                )],
                interval: 1
            )
            #expect(reading.sessionIn == ByteCount(Int64(step * 500)))
        }
        accumulator.reset()
        let afterReset = accumulator.reading(
            from: [InterfaceCounters(name: "en0", kind: .physical, bytesIn: 9_999, bytesOut: 0)],
            interval: 1
        )
        #expect(afterReset.sessionIn == .zero)
    }

    @Test("Interfaces are classified by what they are")
    func interfaceKinds() {
        #expect(NetworkSampler.kind(of: "lo0", type: UInt8(IFT_LOOP)) == .loopback)
        #expect(NetworkSampler.kind(of: "en0", type: 6) == .physical)
        #expect(NetworkSampler.kind(of: "utun4", type: 1) == .virtual)
        #expect(NetworkSampler.kind(of: "awdl0", type: 6) == .virtual)
    }

    // MARK: Naming

    @Test("An application is called by its own name, not its executable path")
    func namesApplications() {
        #expect(ProcessNaming.displayName(
            path: "/Applications/Safari.app/Contents/MacOS/Safari", comm: "Safari"
        ) == "Safari")
        #expect(ProcessNaming.displayName(
            path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            comm: "Finder"
        ) == "Finder")
        #expect(ProcessNaming.displayName(path: "/usr/libexec/countryd", comm: "countryd")
            == "countryd")
        // The kernel's sixteen-character stub is all that is left when the
        // path cannot be read at all.
        #expect(ProcessNaming.displayName(path: nil, comm: "com.apple.fpsd.") == "com.apple.fpsd.")
    }

    @Test("A bundle is found from the executable inside it")
    func findsBundle() {
        #expect(ProcessNaming.bundlePath(for: "/Applications/Safari.app/Contents/MacOS/Safari")
            == "/Applications/Safari.app")
        #expect(ProcessNaming.bundlePath(for: "/usr/libexec/countryd") == nil)
    }

    // MARK: Memory

    @Test("Used memory is applications, wired and compressed together")
    func memoryUsed() {
        let reading = MemoryReading(
            total: ByteCount(16_000_000_000),
            application: ByteCount(4_000_000_000),
            wired: ByteCount(3_000_000_000),
            compressed: ByteCount(1_000_000_000),
            cached: ByteCount(2_000_000_000),
            free: ByteCount(6_000_000_000),
            swapTotal: ByteCount(4_000_000_000),
            swapUsed: ByteCount(1_000_000_000),
            pressure: .normal
        )
        #expect(reading.used == ByteCount(8_000_000_000))
        #expect(abs(reading.usedFraction - 0.5) < 0.0001)
        #expect(abs(reading.swapFraction - 0.25) < 0.0001)
    }

    @Test("The kernel's pressure levels are read as they come")
    func pressureLevels() {
        #expect(MemoryPressure(level: 1) == .normal)
        #expect(MemoryPressure(level: 2) == .warning)
        #expect(MemoryPressure(level: 4) == .critical)
        #expect(MemoryPressure(level: 99) == .unknown)
    }
}
