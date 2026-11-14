import Foundation
import MonitorKit
import Observation
import ScanCore

/// The live instrument's state.
///
/// Unlike every other controller here, this one is not measuring something
/// once and keeping the answer: it is taking a reading several times a
/// second's worth of apart, forever, and each reading costs a few thousand
/// syscalls. So it runs only while the screen is actually on display, stops
/// the moment it is not, and forgets the previous round when it starts again
/// — a rate worked out across a gap when nobody was watching would be an
/// average over minutes printed as a reading for now.
@MainActor
@Observable
final class ActivityController {
    /// Which of the machine's six measures the screen is showing.
    enum Subject: String, CaseIterable, Identifiable, Sendable {
        case processor, memory, processes, energy, disk, network

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .processor: "activity.subject.processor"
            case .memory: "activity.subject.memory"
            case .processes: "activity.subject.processes"
            case .energy: "activity.subject.energy"
            case .disk: "activity.subject.disk"
            case .network: "activity.subject.network"
            }
        }

        /// What the table is sorted by when this subject is chosen.
        var column: ProcessColumn {
            switch self {
            case .processor, .processes: .cpu
            case .memory: .memory
            case .energy: .wakeups
            case .disk, .network: .disk
            }
        }
    }

    /// How often a reading is taken.
    ///
    /// Named rather than numbered because the honest unit is "how closely are
    /// you watching", and because the cost is real: the closest setting reads
    /// seven hundred processes every second.
    enum Cadence: String, CaseIterable, Identifiable, Sendable {
        case close, steady, calm

        var id: String { rawValue }

        var seconds: Double {
            switch self {
            case .close: 1
            case .steady: 2
            case .calm: 5
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .close: "activity.cadence.close"
            case .steady: "activity.cadence.steady"
            case .calm: "activity.cadence.calm"
            }
        }
    }

    /// A column of the process table, and the measure it sorts by.
    enum ProcessColumn: String, CaseIterable, Identifiable, Sendable {
        case name, cpu, memory, threads, wakeups, disk

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .name: "activity.column.name"
            case .cpu: "activity.column.cpu"
            case .memory: "activity.column.memory"
            case .threads: "activity.column.threads"
            case .wakeups: "activity.column.wakeups"
            case .disk: "activity.column.disk"
            }
        }
    }

    let facts: MachineFacts
    private let monitor: SystemMonitor

    private(set) var snapshot: SystemSnapshot?
    private(set) var isWatching = false
    private(set) var startedAt: Date?

    /// Kept across launches, the way the Panel keeps its chosen chart: the
    /// screen should open where it was left rather than on the first tab.
    private static let subjectKey = "activity.subject"
    private static let cadenceKey = "activity.cadence"

    var subject: Subject = .processor {
        didSet {
            guard subject != oldValue else { return }
            sort = subject.column
            descending = true
            AppDefaults.store.set(subject.rawValue, forKey: Self.subjectKey)
        }
    }

    var cadence: Cadence = .steady {
        didSet {
            guard cadence != oldValue else { return }
            AppDefaults.store.set(cadence.rawValue, forKey: Self.cadenceKey)
            guard isWatching else { return }
            // Restart rather than wait out the old interval, so the change is
            // visible at once. The trace goes with it: its points are evenly
            // spaced by definition, and keeping readings taken a second apart
            // next to readings taken five seconds apart would draw a chart
            // whose horizontal axis means two different things.
            stop()
            start()
        }
    }

    var sort: ProcessColumn = .cpu
    var descending = true
    var search = ""

    // MARK: Traces
    //
    // The last few minutes of each measure, so a chart can show where the
    // current figure came from. They are kept here rather than derived from
    // a list of snapshots because a snapshot holds seven hundred processes
    // and keeping a hundred of those would be a hundred thousand structs for
    // the sake of six lines.

    private(set) var processorTrace = Trace()
    private(set) var memoryTrace = Trace()
    private(set) var diskTrace = Trace()
    private(set) var networkTrace = Trace()
    private(set) var energyTrace = Trace()

    private var task: Task<Void, Never>?

    init(facts: MachineFacts = .current()) {
        self.facts = facts
        monitor = SystemMonitor(facts: facts)
        if let stored = AppDefaults.store.string(forKey: Self.subjectKey),
           let chosen = Subject(rawValue: stored) {
            subject = chosen
            sort = chosen.column
        }
        if let stored = AppDefaults.store.string(forKey: Self.cadenceKey),
           let chosen = Cadence(rawValue: stored) {
            cadence = chosen
        }
        #if DEBUG
        // A capture has a couple of seconds to work with, so it reads as
        // closely as the screen allows and has a trace to show by the time
        // the shutter goes.
        if DebugSnapshot.directory != nil {
            cadence = .close
            if let chosen = DebugSnapshot.activitySubject.flatMap(Subject.init(rawValue:)) {
                subject = chosen
                sort = chosen.column
            }
        }
        #endif
    }

    // MARK: Watching

    func start() {
        guard task == nil else { return }
        isWatching = true
        startedAt = .now
        task = Task {
            // The counters kept climbing while nothing was watching, so the
            // first reading of a round is a baseline and nothing else. The
            // trace is dropped for the same reason: a gap in it would be
            // drawn as though it were time that passed quietly.
            await self.monitor.reset()
            self.clearTraces()
            while !Task.isCancelled {
                let reading = await self.monitor.take()
                guard !Task.isCancelled else { return }
                self.apply(reading)
                do {
                    try await Task.sleep(for: .seconds(self.cadence.seconds))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    private func apply(_ reading: SystemSnapshot) {
        snapshot = reading
        // The first reading of a round has no interval behind it, so it has
        // no rates in it either. Plotting it would draw a trough that never
        // happened.
        guard !reading.isFirst else { return }
        processorTrace.append(reading.cpu.busy, reading.cpu.system)
        memoryTrace.append(
            reading.memory?.usedFraction ?? 0,
            reading.memory.map { stack in
                guard stack.total.rawValue > 0 else { return 0 }
                return Double(stack.compressed.rawValue) / Double(stack.total.rawValue)
            } ?? 0
        )
        diskTrace.append(reading.disk?.readPerSecond ?? 0, reading.disk?.writtenPerSecond ?? 0)
        networkTrace.append(reading.network.inPerSecond, reading.network.outPerSecond)
        energyTrace.append(reading.wakeupsPerSecond, 0)
    }

    private func clearTraces() {
        processorTrace = Trace()
        memoryTrace = Trace()
        diskTrace = Trace()
        networkTrace = Trace()
        energyTrace = Trace()
    }

    var trace: Trace {
        switch subject {
        case .processor, .processes: processorTrace
        case .memory: memoryTrace
        case .disk: diskTrace
        case .network: networkTrace
        case .energy: energyTrace
        }
    }

    // MARK: The table

    /// The processes to show, filtered and sorted as the headings say.
    ///
    /// Processes whose figures could not be read sink to the bottom whatever
    /// the sort, because there is nothing to sort them by; they are still
    /// listed, because leaving them out would be a quieter lie than printing
    /// a nought for them.
    var rows: [ProcessReading] {
        guard let snapshot else { return [] }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? snapshot.processes
            : snapshot.processes.filter {
                $0.name.lowercased().contains(needle)
                    || String($0.pid).contains(needle)
            }
        return matching.sorted(by: ordering)
    }

    private func ordering(_ first: ProcessReading, _ second: ProcessReading) -> Bool {
        if sort == .name {
            let result = first.name.localizedStandardCompare(second.name)
            return descending ? result == .orderedDescending : result == .orderedAscending
        }
        let left = measure(of: first)
        let right = measure(of: second)
        if left == right { return first.pid < second.pid }
        return descending ? left > right : left < right
    }

    private func measure(of reading: ProcessReading) -> Double {
        switch sort {
        case .name: 0
        case .cpu: reading.cpu ?? -1
        case .memory: Double(reading.memory?.rawValue ?? -1)
        case .threads: Double(reading.threads ?? -1)
        case .wakeups: reading.wakeupsPerSecond ?? -1
        case .disk: (reading.bytesReadPerSecond ?? -1) + (reading.bytesWrittenPerSecond ?? 0)
        }
    }

    func toggleSort(_ column: ProcessColumn) {
        if sort == column {
            descending.toggle()
        } else {
            sort = column
            descending = column != .name
        }
    }
}

/// A few minutes of one measure, as two series.
///
/// Fixed length, oldest dropped: a chart of the last two hundred readings is
/// the most a strip this size can show without the line becoming a smear, and
/// keeping more would cost memory to draw nothing.
struct Trace: Equatable {
    private(set) var primary: [Double] = []
    private(set) var secondary: [Double] = []
    let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    var isEmpty: Bool { primary.isEmpty }
    var count: Int { primary.count }

    /// The tallest value in the window.
    var peak: Double {
        max(primary.max() ?? 0, secondary.max() ?? 0)
    }

    /// The top of the chart when there is no real ceiling to draw against.
    ///
    /// A little headroom above the tallest reading, and never a scale of
    /// nothing, so a quiet network draws a flat line along the floor rather
    /// than a wall.
    var scale: Double { max(peak * 1.15, 1) }

    mutating func append(_ first: Double, _ second: Double = 0) {
        primary.append(first.isFinite ? max(first, 0) : 0)
        secondary.append(second.isFinite ? max(second, 0) : 0)
        if primary.count > limit { primary.removeFirst(primary.count - limit) }
        if secondary.count > limit { secondary.removeFirst(secondary.count - limit) }
    }
}
