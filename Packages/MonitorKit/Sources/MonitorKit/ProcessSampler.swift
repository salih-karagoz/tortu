import Darwin
import Foundation
import ScanCore

/// One process, as the kernel will describe it to an ordinary user.
///
/// The counters are lifetime totals, which is the only form the kernel keeps
/// them in. Turning them into rates needs two of these; see `ProcessDelta`.
public struct ProcessFacts: Sendable, Equatable, Identifiable {
    public var pid: pid_t
    public var parent: pid_t
    /// The best name available: the application's own name where the
    /// executable lives in a bundle, the executable's name otherwise, and
    /// the kernel's sixteen-character abbreviation as a last resort.
    public var name: String
    public var path: String?
    public var uid: uid_t
    public var started: Date?

    // MARK: Counters
    //
    // All nil together. macOS lets any user see that a process exists and
    // what it is called; it does not let one user read another's figures.
    // Everything a root daemon is doing therefore reads as nil here, and the
    // screen says so rather than printing a nought.

    /// Processor time since the process started, in mach absolute units.
    public var cpuUnits: UInt64?
    /// What the process is really costing in memory, the figure the kernel
    /// bills it for — not its resident set, which double-counts shared pages.
    public var footprint: ByteCount?
    public var resident: ByteCount?
    public var threads: Int?
    /// Wakeups from idle, which is what a laptop's battery actually pays for
    /// beyond processor time.
    public var idleWakeups: UInt64?
    public var bytesRead: UInt64?
    public var bytesWritten: UInt64?

    public var id: pid_t { pid }

    /// Whether the kernel let us read this process's figures.
    public var isReadable: Bool { cpuUnits != nil }

    public init(
        pid: pid_t,
        parent: pid_t = 0,
        name: String,
        path: String? = nil,
        uid: uid_t = 0,
        started: Date? = nil,
        cpuUnits: UInt64? = nil,
        footprint: ByteCount? = nil,
        resident: ByteCount? = nil,
        threads: Int? = nil,
        idleWakeups: UInt64? = nil,
        bytesRead: UInt64? = nil,
        bytesWritten: UInt64? = nil
    ) {
        self.pid = pid
        self.parent = parent
        self.name = name
        self.path = path
        self.uid = uid
        self.started = started
        self.cpuUnits = cpuUnits
        self.footprint = footprint
        self.resident = resident
        self.threads = threads
        self.idleWakeups = idleWakeups
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    /// Processor time since the process started.
    public var cpuTime: TimeInterval? {
        cpuUnits.map(MachClock.seconds)
    }
}

/// A process with rates worked out across an interval.
public struct ProcessReading: Sendable, Equatable, Identifiable {
    public var facts: ProcessFacts
    /// Busy fraction of one core: `1.0` is one core fully occupied, and a
    /// process using four cores reads `4.0`. This is what every other tool
    /// on the machine means by a process's CPU per cent.
    public var cpu: Double?
    public var wakeupsPerSecond: Double?
    public var bytesReadPerSecond: Double?
    public var bytesWrittenPerSecond: Double?

    public var id: pid_t { facts.pid }
    public var pid: pid_t { facts.pid }
    public var name: String { facts.name }
    public var memory: ByteCount? { facts.footprint }
    public var threads: Int? { facts.threads }
    public var isReadable: Bool { facts.isReadable }

    public init(
        facts: ProcessFacts,
        cpu: Double? = nil,
        wakeupsPerSecond: Double? = nil,
        bytesReadPerSecond: Double? = nil,
        bytesWrittenPerSecond: Double? = nil
    ) {
        self.facts = facts
        self.cpu = cpu
        self.wakeupsPerSecond = wakeupsPerSecond
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
    }
}

/// Turns two rounds of lifetime counters into rates.
public enum ProcessDelta {
    /// Rates between two samples.
    ///
    /// A process present in the second sample but not the first has no
    /// interval to measure against, so its rate is taken over its whole life
    /// instead — which for something that has just started is the same thing.
    /// A process whose counter went backwards, which happens when a pid is
    /// reused, is treated as new rather than reported as a negative rate.
    public static func readings(
        from previous: [pid_t: ProcessFacts],
        to current: [ProcessFacts],
        interval: TimeInterval,
        now: Date = .now
    ) -> [ProcessReading] {
        current.map { facts in
            guard facts.isReadable else { return ProcessReading(facts: facts) }

            let before = previous[facts.pid]
            let comparable = before.map { $0.isReadable && $0.started == facts.started } ?? false
            let span: TimeInterval
            let base: ProcessFacts?
            if comparable, interval > 0 {
                span = interval
                base = before
            } else {
                // Its whole life, which is the only span there is for it.
                span = facts.started.map { max(now.timeIntervalSince($0), 0.001) } ?? interval
                base = nil
            }
            guard span > 0 else { return ProcessReading(facts: facts) }

            func rate(_ now: UInt64?, _ then: UInt64?) -> Double? {
                guard let now else { return nil }
                let start = then ?? 0
                guard now >= start else { return nil }
                return Double(now - start) / span
            }

            let cpuUnits = facts.cpuUnits ?? 0
            let previousUnits = base?.cpuUnits ?? 0
            let cpu: Double? = cpuUnits >= previousUnits
                ? MachClock.seconds(cpuUnits - previousUnits) / span
                : nil

            return ProcessReading(
                facts: facts,
                cpu: cpu,
                wakeupsPerSecond: rate(facts.idleWakeups, base?.idleWakeups),
                bytesReadPerSecond: rate(facts.bytesRead, base?.bytesRead),
                bytesWrittenPerSecond: rate(facts.bytesWritten, base?.bytesWritten)
            )
        }
    }
}

/// Reads every process the kernel will admit to.
///
/// A class rather than a value, because it remembers the executable path of
/// every process it has already looked up. Resolving a path is the most
/// expensive of the four calls this makes per process, and across seven
/// hundred processes several times a second it is most of the cost of the
/// screen. The kernel's own abbreviation of the command is read every time
/// regardless, and a cached path is only trusted while that still matches,
/// so a reused pid gets looked up again rather than inheriting a name.
public final class ProcessSampler {
    private var knownPaths: [pid_t: (comm: String, path: String?)] = [:]

    public init() {}

    public func sample() -> [ProcessFacts] {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, capacity)
        guard written > 0 else { return [] }
        let count = min(Int(written) / MemoryLayout<pid_t>.size, pids.count)

        var facts: [ProcessFacts] = []
        facts.reserveCapacity(count)
        var live: Set<pid_t> = []
        live.reserveCapacity(count)
        for pid in pids[0 ..< count] where pid > 0 {
            if let one = read(pid) {
                facts.append(one)
                live.insert(pid)
            }
        }
        // Processes that have gone take their cached name with them.
        if knownPaths.count > live.count { knownPaths = knownPaths.filter { live.contains($0.key) } }
        return facts
    }

    private func read(_ pid: pid_t) -> ProcessFacts? {
        // The short form is the one every user may read, for every process.
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) > 0 else {
            return nil
        }
        let comm = withUnsafeBytes(of: short.pbsi_comm) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }

        let path: String?
        if let known = knownPaths[pid], known.comm == comm {
            path = known.path
        } else {
            // Four kilobytes is `PROC_PIDPATHINFO_MAXSIZE`, which the header
            // declares as a macro Swift cannot see.
            var pathBuffer = [UInt8](repeating: 0, count: 4096)
            path = proc_pidpath(pid, &pathBuffer, 4096) > 0
                ? String(decoding: pathBuffer.prefix { $0 != 0 }, as: UTF8.self)
                : nil
            knownPaths[pid] = (comm: comm, path: path)
        }

        var facts = ProcessFacts(
            pid: pid,
            parent: pid_t(bitPattern: short.pbsi_ppid),
            name: ProcessNaming.displayName(path: path, comm: comm),
            path: path,
            uid: short.pbsi_uid
        )

        // The long form, the task counters and the resource totals all stop
        // at the boundary of another user's processes. Asking is the only way
        // to find out, and a refusal is information in itself.
        var bsd = proc_bsdinfo()
        if proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)
        ) > 0, bsd.pbi_start_tvsec > 0 {
            facts.started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
        }

        var task = proc_taskinfo()
        guard proc_pidinfo(
            pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)
        ) > 0 else { return facts }

        facts.cpuUnits = task.pti_total_user &+ task.pti_total_system
        facts.resident = ByteCount(Int64(clamping: task.pti_resident_size))
        facts.threads = Int(task.pti_threadnum)
        facts.footprint = facts.resident

        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if read == 0 {
            facts.footprint = ByteCount(Int64(clamping: usage.ri_phys_footprint))
            facts.idleWakeups = usage.ri_pkg_idle_wkups
            facts.bytesRead = usage.ri_diskio_bytesread
            facts.bytesWritten = usage.ri_diskio_byteswritten
        }
        return facts
    }
}

/// What to call a process on screen.
public enum ProcessNaming {
    /// The application's own name where there is one, the executable's name
    /// otherwise.
    ///
    /// `/Applications/Safari.app/Contents/MacOS/Safari` and
    /// `/usr/libexec/countryd` both have a sensible answer; only a process
    /// whose path cannot be read falls back to the kernel's abbreviation,
    /// which is cut at sixteen characters and often unrecognisable.
    public static func displayName(path: String?, comm: String) -> String {
        guard let path, !path.isEmpty else { return comm }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if let bundle = components.last(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        return components.last.map(String.init) ?? comm
    }

    /// The bundle the executable lives in, for the places a path is more
    /// use than a name.
    public static func bundlePath(for path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/Contents/") else { return nil }
        return String(path[path.startIndex ..< range.lowerBound]) + ".app"
    }
}
