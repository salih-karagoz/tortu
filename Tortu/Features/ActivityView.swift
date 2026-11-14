import AppKit
import Entitlements
import MonitorKit
import ScanCore
import SwiftUI

/// The live instrument.
///
/// Every other screen in this application measures something slowly and
/// carefully and then shows the answer. This one shows the machine as it is,
/// a reading at a time, and it keeps the same promise under a harder
/// constraint: it prints only what the kernel will tell an ordinary user, it
/// says plainly which processes it is not allowed to read, and where there is
/// no honest figure — an energy score, a per-process network rate — it shows
/// nothing rather than something plausible.
struct ActivityView: View {
    /// Owned by the window: the traces are minutes of history and must not be
    /// thrown away every time the sidebar moves.
    @Bindable var controller: ActivityController
    /// Where the licence is explained, for the build that does not have one.
    var onOpenSettings: () -> Void = {}

    @Environment(\.entitlements) private var entitlements

    private var isUnlocked: Bool { entitlements.isUnlocked(.liveActivity) }

    var body: some View {
        ScreenBody(bottom: 16) {
            ScreenHeader(title: "activity.title", subtitle: machineLine) {
                if isUnlocked { status }
            }
            if isUnlocked {
                strip
                instrument(for: controller.snapshot)
            } else {
                locked
            }
        }
        .onAppear { if isUnlocked { controller.start() } }
        .onDisappear { controller.stop() }
    }

    // MARK: Header

    /// What the figures below are figures of. A percentage of an unknown
    /// number of cores is not a measurement.
    private var machineLine: String {
        let facts = controller.facts
        var parts: [String] = []
        if !facts.chip.isEmpty { parts.append(facts.chip) }
        parts.append(String(localized: "activity.cores \(facts.logicalCores)"))
        parts.append(Figure.memory(facts.physicalMemory, fractionDigits: 0).joined)
        return parts.joined(separator: " · ")
    }

    private var status: some View {
        HStack(spacing: 6) {
            Dot(color: controller.isWatching ? Tone.acc : Tone.b2)
            Note(verbatim: statusLine).sized(12)
        }
    }

    private var statusLine: String {
        guard controller.isWatching else { return String(localized: "activity.paused") }
        let cadence = controller.cadence.seconds
        return String(localized: "activity.cadenceLine \(Int(cadence))")
    }

    // MARK: Strip

    private var strip: some View {
        HStack(spacing: 10) {
            SegmentPicker(
                options: ActivityController.Subject.allCases.map {
                    (value: $0, title: String(localized: $0.title))
                },
                selection: $controller.subject
            )
            Spacer(minLength: 8)
            SegmentPicker(
                options: ActivityController.Cadence.allCases.map {
                    (value: $0, title: String(localized: $0.title))
                },
                selection: $controller.cadence
            )
            Button {
                if controller.isWatching { controller.stop() } else { controller.start() }
            } label: {
                Text(controller.isWatching ? "activity.pause" : "activity.resume")
                    .font(Face.text(12, 500))
                    .foregroundStyle(Tone.sec)
                    .padding(.horizontal, 10)
                    .frame(height: Metric.segmentHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous)
                            .strokeBorder(Tone.b2, lineWidth: Metric.hairline)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: Metric.segmentHeight)
    }

    // MARK: Body

    @ViewBuilder
    private func instrument(for snapshot: SystemSnapshot?) -> some View {
        if let snapshot, !snapshot.isFirst {
            VStack(alignment: .leading, spacing: 12) {
                if controller.subject != .processes {
                    chartBox(snapshot)
                }
                Readout(cells: cells(for: snapshot))
                table(snapshot)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            waiting
        }
    }

    /// The gap between opening the screen and the second reading, which is
    /// the first one that can hold a rate.
    private var waiting: some View {
        WorkingBox(
            title: "activity.working",
            detail: String(localized: "activity.working.detail"),
            started: controller.startedAt
        ) {
            SkeletonList(
                columns: [.flexible(1), .fixed(76), .fixed(60), .fixed(90)],
                cells: [.lines(0.45), .number(0.6), .number(0.5), .number(0.7)],
                rows: 7,
                height: 36
            )
        }
    }

    // MARK: Chart

    private func chartBox(_ snapshot: SystemSnapshot) -> some View {
        ChartFrame(label: chartLabel, range: chartRange) {
            VStack(alignment: .leading, spacing: 10) {
                TraceChart(
                    trace: controller.trace,
                    ceiling: chartCeiling,
                    capacity: controller.trace.limit
                )
                extras(snapshot)
            }
        }
        .frame(height: controller.subject == .memory ? 188 : 164)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(chartLabel))
        .accessibilityValue(Text(verbatim: spokenChart))
    }

    /// The chart, in words: what it reads now and what the window's tallest
    /// reading was. A trace is a shape, and a shape has to be said out loud
    /// to be of any use to somebody who cannot see it.
    private var spokenChart: String {
        let trace = controller.trace
        guard !trace.isEmpty, let latest = trace.primary.last else {
            return String(localized: "activity.chart.spokenEmpty")
        }
        let now: String
        let peak: String
        switch controller.subject {
        case .processor, .processes, .memory:
            now = Figure.percent(latest, digits: 1)
            peak = Figure.percent(trace.peak, digits: 1)
        case .energy:
            now = Figure.rate(latest).joined
            peak = Figure.rate(trace.peak).joined
        case .disk, .network:
            now = Figure.perSecond(latest).joined
            peak = Figure.perSecond(trace.peak).joined
        }
        return String(localized: "activity.chart.spoken \(now) \(peak)")
    }

    private var chartLabel: LocalizedStringResource {
        switch controller.subject {
        case .processor, .processes: "activity.chart.processor"
        case .memory: "activity.chart.memory"
        case .energy: "activity.chart.energy"
        case .disk: "activity.chart.disk"
        case .network: "activity.chart.network"
        }
    }

    /// How far back the chart reaches, and — where the scale is set by the
    /// tallest reading rather than by a ceiling — what the top of it is.
    private var chartRange: String {
        let seconds = Int(Double(controller.trace.count) * controller.cadence.seconds)
        let span = String(
            localized: "activity.span \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))"
        )
        guard chartCeiling == nil else { return span }
        let peak = controller.subject == .energy
            ? Figure.rate(controller.trace.scale).joined
            : Figure.perSecond(controller.trace.scale).joined
        return String(localized: "activity.scale \(peak)") + " · " + span
    }

    /// A ceiling only where there genuinely is one. A processor cannot be
    /// more than fully busy; a network can always be busier than it is.
    private var chartCeiling: Double? {
        switch controller.subject {
        case .processor, .processes, .memory: 1
        case .energy, .disk, .network: nil
        }
    }

    /// What goes under the trace, where the subject has a second thing worth
    /// drawing.
    @ViewBuilder
    private func extras(_ snapshot: SystemSnapshot) -> some View {
        switch controller.subject {
        case .processor:
            if !snapshot.cpu.cores.isEmpty {
                CoreBars(cores: snapshot.cpu.cores)
                    .frame(height: 30)
            }
        case .memory:
            if let memory = snapshot.memory {
                CompositionBar(parts: memoryParts(memory))
            }
        case .network:
            interfaceKey
        case .disk:
            ChartKey(items: [
                ChartKey.Item(
                    id: "read", label: String(localized: "activity.read"), color: Tone.acc
                ),
                ChartKey.Item(
                    id: "write", label: String(localized: "activity.write"),
                    color: Tone.ink.opacity(0.45)
                ),
            ])
        case .energy, .processes:
            EmptyView()
        }
    }

    private var interfaceKey: some View {
        ChartKey(items: [
            ChartKey.Item(id: "in", label: String(localized: "activity.in"), color: Tone.acc),
            ChartKey.Item(
                id: "out", label: String(localized: "activity.out"),
                color: Tone.ink.opacity(0.45)
            ),
        ])
    }

    private func memoryParts(_ memory: MemoryReading) -> [CompositionBar.Part] {
        let total = Double(max(memory.total.rawValue, 1))
        func share(_ count: ByteCount) -> Double { Double(count.rawValue) / total }
        return [
            .init("app", "activity.memory.application", share(memory.application), Tone.acc),
            .init("wired", "activity.memory.wired", share(memory.wired), Tone.step(1)),
            .init(
                "compressed", "activity.memory.compressed", share(memory.compressed), Tone.step(3)
            ),
            .init("cached", "activity.memory.cached", share(memory.cached), Tone.step(5)),
        ]
    }

    // MARK: Readout

    private func cells(for snapshot: SystemSnapshot) -> [Readout.Cell] {
        switch controller.subject {
        case .processor: processorCells(snapshot)
        case .memory: memoryCells(snapshot)
        case .processes: processCells(snapshot)
        case .energy: energyCells(snapshot)
        case .disk: diskCells(snapshot)
        case .network: networkCells(snapshot)
        }
    }

    private func processorCells(_ snapshot: SystemSnapshot) -> [Readout.Cell] {
        var cells: [Readout.Cell] = [
            .number("activity.busy", Figure.Measure(
                value: Figure.percent(snapshot.cpu.busy, digits: 1), unit: ""
            ), tone: Tone.acct),
            .number("activity.system", Figure.Measure(
                value: Figure.percent(snapshot.cpu.system, digits: 1), unit: ""
            )),
        ]
        if let utilisation = snapshot.gpu.utilisation {
            cells.append(.number("activity.gpu", Figure.Measure(
                value: Figure.percent(utilisation, digits: 0), unit: ""
            )))
        }
        if let load = snapshot.loadAverage.first {
            cells.append(.number("activity.load", Figure.Measure(
                value: load.formatted(.number.precision(.fractionLength(2))), unit: ""
            )))
        }
        cells.append(.number(
            "activity.threads",
            Figure.Measure(value: Figure.count(snapshot.threadCount), unit: "")
        ))
        return cells
    }

    private func memoryCells(_ snapshot: SystemSnapshot) -> [Readout.Cell] {
        guard let memory = snapshot.memory else { return [] }
        return [
            .number("activity.memory.used", Figure.memory(memory.used), tone: Tone.acct),
            .number("activity.memory.compressed", Figure.memory(memory.compressed)),
            .number("activity.memory.swap", Figure.memory(memory.swapUsed)),
            .word("activity.memory.pressure", pressureText(memory.pressure),
                  tone: memory.pressure == .normal ? Tone.ink : Tone.acct),
            .number("activity.memory.free", Figure.memory(memory.free + memory.cached)),
        ]
    }

    private func processCells(_ snapshot: SystemSnapshot) -> [Readout.Cell] {
        [
            .number(
                "activity.processes.total",
                Figure.Measure(value: Figure.count(snapshot.processCount), unit: "")
            ),
            .number(
                "activity.threads",
                Figure.Measure(value: Figure.count(snapshot.threadCount), unit: "")
            ),
            .number(
                "activity.processes.closed",
                Figure.Measure(value: Figure.count(snapshot.closedProcesses), unit: ""),
                tone: snapshot.closedProcesses > 0 ? Tone.sec : Tone.ink
            ),
            .number("activity.busy", Figure.Measure(
                value: Figure.percent(snapshot.cpu.busy, digits: 1), unit: ""
            )),
        ]
    }

    private func energyCells(_ snapshot: SystemSnapshot) -> [Readout.Cell] {
        let power = snapshot.power
        var cells: [Readout.Cell] = [
            .word("activity.energy.source", sourceText(power)),
        ]
        if let charge = power.charge {
            cells.append(.number("activity.energy.charge", Figure.Measure(
                value: Figure.percent(charge, digits: 0), unit: ""
            )))
        }
        if let watts = power.batteryWatts {
            cells.append(.number("activity.energy.draw", Figure.Measure(
                value: watts.formatted(.number.precision(.fractionLength(1))), unit: "W"
            ), tone: Tone.acct))
        }
        if let remaining = power.timeRemaining {
            cells.append(.word(
                "activity.energy.remaining",
                Duration.seconds(Int(remaining)).formatted(.time(pattern: .hourMinute))
            ))
        }
        cells.append(.number(
            "activity.energy.wakeups", Figure.rate(snapshot.wakeupsPerSecond)
        ))
        cells.append(.word("activity.energy.thermal", thermalText(power.thermal),
                           tone: power.thermal == .nominal ? Tone.ink : Tone.acct))
        return cells
    }

    private func diskCells(_ snapshot: SystemSnapshot) -> [Readout.Cell] {
        guard let disk = snapshot.disk else { return [] }
        return [
            .number("activity.read", Figure.perSecond(disk.readPerSecond), tone: Tone.acct),
            .number("activity.write", Figure.perSecond(disk.writtenPerSecond)),
            .number("activity.disk.operations", Figure.rate(
                disk.readsPerSecond + disk.writesPerSecond
            )),
            .number("activity.disk.processes", Figure.perSecond(snapshot.processBytesPerSecond)),
        ]
    }

    private func networkCells(_ snapshot: SystemSnapshot) -> [Readout.Cell] {
        let network = snapshot.network
        return [
            .number("activity.in", Figure.perSecond(network.inPerSecond), tone: Tone.acct),
            .number("activity.out", Figure.perSecond(network.outPerSecond)),
            .number("activity.network.sessionIn", Figure.bytes(network.sessionIn)),
            .number("activity.network.sessionOut", Figure.bytes(network.sessionOut)),
        ]
    }

    private func pressureText(_ pressure: MemoryPressure) -> String {
        let key: LocalizedStringResource = switch pressure {
        case .normal: "activity.pressure.normal"
        case .warning: "activity.pressure.warning"
        case .critical: "activity.pressure.critical"
        case .unknown: "activity.unknown"
        }
        return String(localized: key)
    }

    private func sourceText(_ power: PowerReading) -> String {
        if power.isCharging { return String(localized: "activity.energy.charging") }
        let key: LocalizedStringResource = switch power.source {
        case .ac: "activity.energy.mains"
        case .battery: "activity.energy.battery"
        case .unknown: "activity.unknown"
        }
        return String(localized: key)
    }

    private func thermalText(_ level: ThermalLevel) -> String {
        let key: LocalizedStringResource = switch level {
        case .nominal: "activity.thermal.nominal"
        case .fair: "activity.thermal.fair"
        case .serious: "activity.thermal.serious"
        case .critical: "activity.thermal.critical"
        }
        return String(localized: key)
    }

    // MARK: Tables

    @ViewBuilder
    private func table(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tableHeader(snapshot)
            if controller.subject == .network {
                InterfaceTable(interfaces: snapshot.network.active)
            } else {
                ProcessTable(
                    rows: controller.rows,
                    columns: columns,
                    sort: controller.sort,
                    descending: controller.descending,
                    toggle: { controller.toggleSort($0) }
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tableHeader(_ snapshot: SystemSnapshot) -> some View {
        HStack(spacing: 10) {
            SectionLabel(controller.subject == .network
                ? "activity.table.interfaces" : "activity.table.processes")
            if controller.subject != .network {
                Note(verbatim: countLine(snapshot)).sized(11)
            }
            Spacer(minLength: 8)
            if controller.subject != .network {
                SearchField(prompt: "activity.search", text: $controller.search)
                    .frame(width: 180)
            }
        }
    }

    /// How many processes there are and how many of them this application is
    /// allowed to read. The shortfall is stated every time, because every
    /// figure in the table above is a figure about the readable ones only.
    private func countLine(_ snapshot: SystemSnapshot) -> String {
        guard snapshot.closedProcesses > 0 else {
            return String(localized: "activity.counts.all \(snapshot.processCount)")
        }
        return String(
            localized: "activity.counts \(snapshot.processCount) \(snapshot.closedProcesses)"
        )
    }

    private var columns: [ActivityController.ProcessColumn] {
        switch controller.subject {
        case .processor: [.name, .cpu, .threads, .memory]
        case .memory: [.name, .memory, .cpu, .threads]
        case .processes: [.name, .cpu, .memory, .threads, .wakeups]
        case .energy: [.name, .wakeups, .cpu, .memory]
        case .disk: [.name, .disk, .cpu, .memory]
        case .network: []
        }
    }

    // MARK: Locked

    private var locked: some View {
        PaidScreen(
            title: "activity.title",
            summary: "activity.locked.summary",
            points: [
                "activity.locked.point.processor",
                "activity.locked.point.memory",
                "activity.locked.point.processes",
                "activity.locked.point.energy",
                "activity.locked.point.traffic",
                "activity.locked.point.honest",
            ],
            action: (title: "activity.locked.action", run: onOpenSettings)
        )
    }
}

// MARK: - Readout

/// The row of live figures under the chart.
struct Readout: View {
    struct Cell: Identifiable {
        let id: String
        let label: LocalizedStringResource
        let measure: Figure.Measure?
        let text: String?
        let tone: Color

        static func number(
            _ label: LocalizedStringResource,
            _ measure: Figure.Measure,
            tone: Color = Tone.ink
        ) -> Cell {
            Cell(id: String(localized: label), label: label, measure: measure, text: nil, tone: tone)
        }

        static func word(
            _ label: LocalizedStringResource,
            _ text: String,
            tone: Color = Tone.ink
        ) -> Cell {
            Cell(id: String(localized: label), label: label, measure: nil, text: text, tone: tone)
        }
    }

    let cells: [Cell]

    var body: some View {
        HairBox(padding: EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14)) {
            HStack(alignment: .top, spacing: 26) {
                ForEach(cells) { cell in
                    VStack(alignment: .leading, spacing: 2) {
                        if let measure = cell.measure {
                            BigNumber(
                                measure: measure, size: 21, unitSize: 11, color: cell.tone
                            )
                        } else {
                            Text(verbatim: cell.text ?? "—")
                                .font(Face.display(16, 600))
                                .foregroundStyle(cell.tone)
                                .lineLimit(1)
                                .frame(height: 26, alignment: .bottomLeading)
                        }
                        SectionLabel(cell.label)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Process table

private struct ProcessTable: View {
    let rows: [ProcessReading]
    let columns: [ActivityController.ProcessColumn]
    let sort: ActivityController.ProcessColumn
    let descending: Bool
    let toggle: (ActivityController.ProcessColumn) -> Void

    private var layout: [ColumnRow.Column] {
        columns.map { column in
            switch column {
            case .name: .flexible(1)
            case .cpu: .fixed(76)
            case .memory: .fixed(90)
            case .threads: .fixed(58)
            case .wakeups: .fixed(104)
            case .disk: .fixed(104)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headings
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        ProcessRow(reading: row, columns: columns, layout: layout)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
    }

    private var headings: some View {
        ColumnRow(columns: layout, spacing: 12) {
            ForEach(columns) { column in
                Button { toggle(column) } label: {
                    HStack(spacing: 4) {
                        if column != .name { Spacer(minLength: 0) }
                        SectionLabel(column.title)
                            .tinted(sort == column ? Tone.acct : Tone.muted)
                            .lineLimit(1)
                            .fixedSize()
                        if sort == column {
                            // A caret rather than a glyph from a font the
                            // design does not otherwise use.
                            Caret(up: !descending)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Tone.soft.opacity(0.5))
    }
}

private struct ProcessRow: View {
    let reading: ProcessReading
    let columns: [ActivityController.ProcessColumn]
    let layout: [ColumnRow.Column]

    var body: some View {
        ColumnRow(columns: layout, spacing: 12) {
            ForEach(columns) { column in
                cell(column)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .opacity(reading.isReadable ? 1 : 0.72)
        .contentShape(Rectangle())
        .contextMenu {
            if let path = reading.facts.path, !path.isEmpty {
                Button("activity.reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
                Button("activity.copyPath") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            Button("activity.copyPid") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(reading.pid), forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func cell(_ column: ActivityController.ProcessColumn) -> some View {
        switch column {
        case .name:
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: reading.name)
                    .font(Face.text(12.5, 600))
                    .foregroundStyle(Tone.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(verbatim: String(reading.pid))
                        .font(Face.display(10.5))
                        .foregroundStyle(Tone.muted)
                    if !reading.isReadable {
                        Badge("activity.closedBadge")
                    }
                }
            }
            .help(reading.facts.path ?? reading.name)
        case .cpu:
            figure(reading.cpu.map { Figure.percent($0, digits: 1) }, emphasise: (reading.cpu ?? 0) > 0.1)
        case .memory:
            figure(reading.memory.map { Figure.memory($0).joined })
        case .threads:
            figure(reading.threads.map(Figure.count))
        case .wakeups:
            figure(reading.wakeupsPerSecond.map { Figure.count(Int($0.rounded())) })
        case .disk:
            figure(diskText, emphasise: (reading.bytesReadPerSecond ?? 0)
                + (reading.bytesWrittenPerSecond ?? 0) > 0)
        }
    }

    private var diskText: String? {
        guard let read = reading.bytesReadPerSecond,
              let written = reading.bytesWrittenPerSecond else { return nil }
        return Figure.perSecond(read + written).joined
    }

    /// A figure, or an em dash where the kernel would not say.
    private func figure(_ text: String?, emphasise: Bool = false) -> some View {
        Text(verbatim: text ?? "—")
            .font(Face.display(12.5, text == nil ? 500 : 600))
            .foregroundStyle(text == nil ? Tone.muted : (emphasise ? Tone.acct : Tone.ink))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The small triangle that says which way a column is sorted.
private struct Caret: View {
    let up: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if up {
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height))
            } else {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            path.closeSubpath()
            context.fill(path, with: .color(Tone.acct))
        }
        .frame(width: 6, height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Interface table

/// What each network interface is carrying.
///
/// Interfaces rather than processes, because macOS will not tell an
/// unprivileged application which process a packet belonged to. Splitting the
/// total between applications by guesswork would be the one thing this screen
/// must not do, so it shows the real division it does have instead.
private struct InterfaceTable: View {
    let interfaces: [InterfaceReading]

    private let layout: [ColumnRow.Column] = [
        .flexible(1), .fixed(84), .fixed(96), .fixed(96), .fixed(116), .fixed(116),
    ]

    var body: some View {
        VStack(spacing: 0) {
            headings
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(interfaces.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline() }
                        row(item)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
    }

    private var headings: some View {
        ColumnRow(columns: layout, spacing: 12) {
            SectionLabel("activity.interface").lineLimit(1)
            SectionLabel("activity.interface.kind").lineLimit(1)
            trailing("activity.in")
            trailing("activity.out")
            trailing("activity.network.sessionIn")
            trailing("activity.network.sessionOut")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Tone.soft.opacity(0.5))
    }

    private func trailing(_ label: LocalizedStringResource) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            SectionLabel(label).lineLimit(1).fixedSize()
        }
    }

    private func row(_ item: InterfaceReading) -> some View {
        ColumnRow(columns: layout, spacing: 12) {
            Text(verbatim: item.name)
                .font(Face.text(12.5, 600))
                .foregroundStyle(item.kind == .physical ? Tone.ink : Tone.sec)
                .lineLimit(1)
            kindBadge(item.kind)
            figure(Figure.perSecond(item.inPerSecond).joined, lit: item.inPerSecond > 0)
            figure(Figure.perSecond(item.outPerSecond).joined, lit: item.outPerSecond > 0)
            figure(Figure.bytes(item.sessionIn).joined, lit: false)
            figure(Figure.bytes(item.sessionOut).joined, lit: false)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func kindBadge(_ kind: InterfaceKind) -> some View {
        switch kind {
        case .physical: Badge("activity.interface.physical", kind: .accent)
        case .loopback: Badge("activity.interface.loopback")
        case .virtual: Badge("activity.interface.virtual")
        }
    }

    private func figure(_ text: String, lit: Bool) -> some View {
        Text(verbatim: text)
            .font(Face.display(12.5, 600))
            .foregroundStyle(lit ? Tone.acct : Tone.sec)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
