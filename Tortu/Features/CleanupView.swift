import CleanerKit
import Foundation
import RulesEngine
import ScanCore
import SwiftData
import SwiftUI

/// The Cleanup screen.
///
/// Its shape follows one promise: the estimate and what the volume actually
/// gave back are always on screen together. The last run sits in a box at the
/// top with both bars drawn to the same scale, and a run started here writes
/// its result straight back into that box rather than into a dialog that
/// disappears.
struct CleanupView: View {
    /// Held by the window rather than here, so that which rules the list is
    /// showing is still what the user chose when they come back to it.
    @Binding var filter: RuleFilter

    @Environment(CleanupController.self) private var controller
    @Environment(\.modelContext) private var context

    @Query(sort: \CleanupRecord.timestamp, order: .reverse) private var records: [CleanupRecord]

    enum RuleFilter: String, CaseIterable, Identifiable {
        case all, selected, locked
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .all: "cleanup.filter.all"
            case .selected: "cleanup.filter.selected"
            case .locked: "cleanup.filter.locked"
            }
        }
    }

    private static let columns: [ColumnRow.Column] = [
        .fixed(30), .flexible(1), .fixed(90), .flexible(1.1),
    ]

    var body: some View {
        ScreenBody(bottom: 16) {
            ScreenHeader(title: "cleanup.title", subtitle: subtitle) {
                SegmentPicker(
                    options: RuleFilter.allCases.map {
                        (value: $0, title: String(localized: $0.title))
                    },
                    selection: $filter
                )
            }

            if let record = records.first(where: { !$0.wasDryRun }) {
                LastRunBox(record: record, scale: lastRunScale(record))
            }

            content

            if controller.plan != nil {
                footer
            }
        }
        .onAppear { controller.loadCatalog() }
        .task {
            let recorder = HistoryRecorder(context: context)
            controller.onAnalysed = { recorder.recordCategories($0) }
            controller.onFinished = { recorder.recordCleanup($0, plan: $1, ruleIDs: $2) }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if controller.ruleCount > 0 {
            parts.append(String(localized: "cleanup.subtitle.rules \(controller.ruleCount)"))
        }
        if let plan = controller.plan {
            parts.append(String(
                localized: "cleanup.subtitle.found \(Figure.bytes(plan.estimatedReclaim).joined)"
            ))
        }
        if let scanned = controller.lastAnalysis {
            parts.append(String(
                localized: "cleanup.subtitle.scanned \(scanned.formatted(date: .omitted, time: .shortened))"
            ))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            Placeholder(
                message: "cleanup.idle",
                action: (title: "cleanup.scan", run: { controller.analyse() })
            )

        case let .analysing(state):
            // The rules are measured together, so this can say how many of
            // them have come back and how much they have found between them
            // — both real figures, climbing, over the outline of the list
            // they are about to fill.
            WorkingBox(
                title: "cleanup.analysing",
                figures: [
                    WorkingFigure("working.rules", done: state.measured, of: state.total),
                    WorkingFigure("working.found", Figure.bytes(state.found)),
                ],
                detail: state.rule,
                fraction: state.fraction,
                started: controller.startedAt,
                stop: { controller.reset() }
            ) {
                skeletonRules
            }

        case let .running(state):
            // A removal under way is never offered a stop: stopping it would
            // leave the work half done without making anything recoverable.
            WorkingBox(
                title: "cleanup.running",
                figures: [
                    WorkingFigure("working.paths", done: state.done, of: state.total),
                ],
                detail: state.path.map(shortPath),
                fraction: state.fraction,
                started: controller.startedAt
            ) {
                skeletonRules
            }

        case let .failed(message):
            Placeholder(
                message: "cleanup.failed",
                detail: message,
                action: (title: "cleanup.scan", run: { controller.analyse() })
            )

        case let .ready(plan), let .finished(_, plan):
            ruleList(plan)
        }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// The rule list's own shape: the same four columns, the same card row.
    private var skeletonRules: some View {
        SkeletonList(
            columns: Self.columns,
            cells: [.check, .lines(0.6), .number(0.65), .line(0.55)],
            rows: 6,
            height: 50,
            style: .cards
        )
    }

    private func ruleList(_ plan: CleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ColumnRow(columns: Self.columns) {
                Button {
                    controller.setAll(controller.selectedCount < plan.actionable.count)
                } label: {
                    CheckBox(isOn: controller.selectedCount == plan.actionable.count
                        && !plan.actionable.isEmpty)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("cleanup.selectAll"))

                SectionLabel("cleanup.column.rule")
                SectionLabel("cleanup.column.found")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                SectionLabel("cleanup.column.cost")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visibleRows(plan)) { evaluation in
                        RuleRow(evaluation: evaluation, columns: Self.columns)
                    }
                    if visibleRows(plan).isEmpty {
                        Note("cleanup.filter.empty")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Rules the current filter shows, biggest first. A rule that found
    /// nothing is still listed under "all", because knowing a rule looked and
    /// found nothing is itself an answer.
    private func visibleRows(_ plan: CleanupPlan) -> [RuleEvaluation] {
        let sorted = plan.evaluations.sorted { $0.reclaimable > $1.reclaimable }
        return switch filter {
        case .all: sorted
        case .selected: sorted.filter { controller.isSelected($0.id) }
        case .locked: sorted.filter { !$0.blockingApplications.isEmpty }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BigNumber(measure: Figure.bytes(controller.selectedReclaim), size: 22, unitSize: 13)
                Note(verbatim: String(
                    localized: "cleanup.footer.selected \(controller.selectedCount)"
                ))
                .tinted(Tone.sec)
                .sized(12)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button { controller.analyse() } label: { Text("cleanup.restart") }
                    .buttonStyle(.secondaryAction)
                Button { controller.run(mode: .dryRun) } label: { Text("cleanup.dryRun") }
                    .buttonStyle(.secondaryAction)
                Button { controller.run(mode: .execute) } label: { Text("cleanup.clean") }
                    .buttonStyle(.primaryAction)
                    .disabled(controller.selectedCount == 0)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .fill(Tone.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
        .shadow(color: Tone.shadow, radius: 12, x: 0, y: 8)
        .disabled(controller.isBusy)
    }

    /// Both bars in the last-run box are drawn against the larger of the two
    /// figures, so a run that came up short looks short.
    private func lastRunScale(_ record: CleanupRecord) -> Int64 {
        max(record.estimatedBytes, record.reclaimedBytes, 1)
    }
}

// MARK: - Rows

private struct RuleRow: View {
    @Environment(CleanupController.self) private var controller

    let evaluation: RuleEvaluation
    let columns: [ColumnRow.Column]

    private var isLocked: Bool { !evaluation.blockingApplications.isEmpty }
    private var isActionable: Bool { evaluation.isActionable }
    private var isSelected: Bool { controller.isSelected(evaluation.id) }
    private var isExpanded: Bool { controller.isExpanded(evaluation.id) }
    private var canExpand: Bool { !evaluation.candidates.isEmpty || !evaluation.kept.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header.background(rowFill)
            if isExpanded, canExpand {
                Hairline()
                // On the window ground rather than the row's tint: twenty
                // rows of it would turn the card into a slab of colour.
                PathList(evaluation: evaluation, columns: columns)
                    .background(Tone.bg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: Metric.hairline)
        )
    }

    private var header: some View {
        ColumnRow(columns: columns) {
            // The box and the disclosure share the design's thirty point
            // column: the box on the grid line, the chevron in the gutter
            // next to it. The rule's name then starts exactly where the
            // column heading above it does, and the two controls sit
            // together instead of a column's width apart.
            HStack(spacing: 0) {
                Button { controller.toggle(evaluation.id) } label: {
                    CheckBox(isOn: isSelected && isActionable, isEnabled: isActionable)
                }
                .buttonStyle(.plain)
                .disabled(!isActionable)
                .accessibilityLabel(Text(verbatim: evaluation.rule.name.resolved()))

                Spacer(minLength: 0)

                // A rule is a pattern; this opens it out into what the
                // pattern actually matched on this machine.
                Button { controller.toggleExpansion(evaluation.id) } label: {
                    Chevron(isOpen: isExpanded)
                        .frame(width: 15, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canExpand)
                .opacity(canExpand ? 1 : 0)
                .accessibilityLabel(Text("cleanup.paths.show"))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(evaluation.rule.name.resolved())
                    .font(Face.text(13, 600))
                    .foregroundStyle(isLocked ? Tone.muted : Tone.ink)
                    .lineLimit(1)
                meta
            }

            BigNumber(
                measure: Figure.bytes(evaluation.reclaimable),
                size: 16, unitSize: 11,
                color: isLocked ? Tone.muted : Tone.ink,
                unitColor: Tone.muted,
                unitInText: true
            )
            .frame(maxWidth: .infinity, alignment: .trailing)

            cost
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if isActionable { controller.toggle(evaluation.id) } }
    }

    private var meta: some View {
        HStack(spacing: 0) {
            Text(String(localized: "cleanup.row.paths \(evaluation.candidates.count)"))
                .font(Face.text(11))
                .foregroundStyle(Tone.muted)
            if excludedCount > 0 {
                Text(verbatim: " · ")
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                Text(String(localized: "cleanup.row.excluded \(excludedCount)"))
                    .font(Face.text(11, 600))
                    .foregroundStyle(Tone.sec)
            }
            Text(verbatim: " · ")
                .font(Face.text(11))
                .foregroundStyle(Tone.muted)
            if case let .keepNewest(count) = evaluation.rule.strategy, count > 0 {
                // The protection is the single most reassuring thing on the
                // row, so it takes the accent and displaces the path.
                Text(String(localized: "cleanup.row.keeping \(count)"))
                    .font(Face.text(11, 600))
                    .foregroundStyle(Tone.acct)
            } else {
                Text(verbatim: displayPath)
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var cost: some View {
        if isLocked {
            HStack(spacing: 6) {
                Badge("cleanup.badge.locked")
                Text(verbatim: evaluation.blockingApplications.joined(separator: ", "))
                    .font(Face.text(12))
                    .foregroundStyle(Tone.sec)
                    .lineLimit(1)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(evaluation.rule.cost.resolved())
                    .font(Face.text(12))
                    .foregroundStyle(Tone.sec)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)
                if evaluation.rule.requiresRoot {
                    Badge("cleanup.badge.admin", kind: .accent)
                }
            }
        }
    }

    /// How many of this rule's paths the user has struck out.
    private var excludedCount: Int {
        guard isSelected else { return 0 }
        return evaluation.candidates.count - controller.remaining(of: evaluation).count
    }

    /// The first pattern the rule matches, with the home directory written as
    /// a tilde the way the user would type it.
    private var displayPath: String {
        guard let first = evaluation.rule.paths.first else { return "" }
        return first.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var rowFill: Color {
        if isLocked { return Tone.softer }
        return isSelected && isActionable ? Tone.tint : .clear
    }

    private var rowBorder: Color {
        isSelected && isActionable ? Tone.acc : Tone.line
    }
}

// MARK: - Last run

/// The estimate and the outcome, side by side, to the same scale.
private struct LastRunBox: View {
    let record: CleanupRecord
    let scale: Int64

    var body: some View {
        HairBox(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
            ColumnRow(columns: [.fixed(150), .flexible(1), .flexible(1.1)], spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("cleanup.lastRun.label")
                    Text(verbatim: when)
                        .font(Face.text(11.5))
                        .foregroundStyle(Tone.sec)
                }

                VStack(alignment: .leading, spacing: 4) {
                    bar(
                        title: "cleanup.lastRun.estimated",
                        measure: Figure.bytes(ScanCore.ByteCount(record.estimatedBytes)),
                        valueColor: Tone.ink
                    ) {
                        GhostBar(fraction: Double(record.estimatedBytes) / Double(scale))
                    }
                    bar(
                        title: "cleanup.lastRun.reclaimed",
                        measure: Figure.bytes(ScanCore.ByteCount(record.reclaimedBytes)),
                        valueColor: Tone.acct
                    ) {
                        TrackBar(
                            fraction: Double(record.reclaimedBytes) / Double(scale),
                            height: 8, fill: Tone.acc
                        )
                    }
                }

                Text(verdict)
                    .font(Face.text(11.5))
                    .foregroundStyle(Tone.sec)
                    .lineSpacing(1.45)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bar<Content: View>(
        title: LocalizedStringResource,
        measure: Figure.Measure,
        valueColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Face.text(11.5))
                    .foregroundStyle(Tone.sec)
                Spacer(minLength: 8)
                Text(measure.joined)
                    .font(Face.display(11.5, 600))
                    .foregroundStyle(valueColor)
            }
            content()
        }
    }

    private var when: String {
        let count = record.ruleIDs.isEmpty ? 0 : record.ruleIDs.split(separator: ",").count
        return String(
            localized: "cleanup.lastRun.when \(record.timestamp.formatted(.dateTime.day().month(.wide).hour().minute())) \(count)"
        )
    }

    /// What the difference between the two bars means, stated without
    /// inventing a cause the app did not measure.
    private var verdict: AttributedString {
        let difference = record.estimatedBytes - record.reclaimedBytes
        let magnitude = Figure.bytes(ScanCore.ByteCount(abs(difference))).joined

        var text: AttributedString
        if difference > record.estimatedBytes / 20 {
            text = AttributedString(String(localized: "cleanup.lastRun.short \(magnitude)"))
        } else if difference < -record.estimatedBytes / 20 {
            text = AttributedString(String(localized: "cleanup.lastRun.over \(magnitude)"))
        } else {
            text = AttributedString(String(localized: "cleanup.lastRun.matched"))
        }
        if record.skippedCount > 0 {
            text += AttributedString(
                " " + String(localized: "cleanup.lastRun.skipped \(record.skippedCount)")
            )
        }
        return text
    }
}

// MARK: - Paths behind a rule

/// What a rule actually matched, listed under it.
///
/// The name on each row is the part of the path that is *not* the same in
/// all of them: for fourteen `node_modules` directories that is the project,
/// which is the thing the user is deciding about. The full path is one hover
/// away rather than wrapped across two lines, because this list can run to
/// hundreds of rows and the project names are what is being read.
private struct PathList: View {
    @Environment(CleanupController.self) private var controller

    let evaluation: RuleEvaluation
    let columns: [ColumnRow.Column]

    /// How many paths are worth listing one by one.
    ///
    /// A rule like `~/**/node_modules` matches a project each, and all of
    /// them fit. A hash-bucketed cache matches hundreds of directories named
    /// `6d` and `0f`, where listing every one buries the next rule and tells
    /// the user nothing they can act on. So the biggest are listed and the
    /// rest are summed up on one line.
    private static let limit = 20

    /// Biggest first: the one worth a second look is almost always the one
    /// taking the space.
    private var sorted: [CandidatePath] {
        evaluation.candidates.sorted { $0.size > $1.size }
    }

    private var candidates: [CandidatePath] {
        Array(sorted.prefix(Self.limit))
    }

    private var overflow: [CandidatePath] {
        Array(sorted.dropFirst(Self.limit))
    }

    private var kept: [CandidatePath] {
        evaluation.kept.sorted { $0.size > $1.size }
    }

    private var names: [String: String] {
        PathNaming.names(for: (evaluation.candidates + evaluation.kept).map(\.path))
    }

    var body: some View {
        let names = names
        VStack(spacing: 0) {
            ForEach(candidates) { candidate in
                row(candidate, name: names[candidate.path] ?? candidate.path, isKept: false)
            }
            if !overflow.isEmpty {
                let total = overflow.reduce(ByteCount.zero) { $0 + $1.size }
                Note(verbatim: String(
                    localized: "cleanup.paths.more \(overflow.count) \(Figure.bytes(total).joined)"
                ))
                .padding(.leading, 14 + 30 + 12)
                .padding(.trailing, 14)
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !kept.isEmpty {
                // The rule protects these. Saying so here is the whole point
                // of opening the rule: "keep the newest three" is a promise
                // the user should be able to see kept.
                HStack(spacing: 8) {
                    SectionLabel("cleanup.paths.kept")
                    Hairline()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ForEach(kept) { candidate in
                    row(candidate, name: names[candidate.path] ?? candidate.path, isKept: true)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func row(_ candidate: CandidatePath, name: String, isKept: Bool) -> some View {
        let isOn = !isKept && controller.isPathSelected(candidate.path, in: evaluation)
        return ColumnRow(columns: columns) {
            Group {
                if isKept {
                    Color.clear.frame(height: 1)
                } else {
                    Button { controller.togglePath(candidate.path, in: evaluation) } label: {
                        CheckBox(isOn: isOn, isEnabled: controller.isSelected(evaluation.id))
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.isSelected(evaluation.id))
                    .accessibilityLabel(Text(verbatim: name))
                }
            }
            // Directly under the disclosure that opened them, which is as
            // much hierarchy as one level needs.
            .padding(.leading, 15)

            Text(verbatim: name)
                .font(Face.text(12, isKept ? 400 : 500))
                .foregroundStyle(isOn ? Tone.ink : Tone.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: Figure.bytes(candidate.size).joined)
                .font(Face.display(12, 600))
                .foregroundStyle(isOn ? Tone.sec : Tone.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if isKept {
                Badge("cleanup.paths.keptBadge", kind: .accent)
            } else {
                Text(verbatim: candidate.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isKept else { return }
            controller.togglePath(candidate.path, in: evaluation)
        }
        .help(Text(verbatim: candidate.path.replacingOccurrences(
            of: NSHomeDirectory(), with: "~"
        )))
    }
}

/// Works out what tells a set of paths apart.
enum PathNaming {
    /// Strips what every path has in common from the front, and the shared
    /// last component from the end, so `~/work/api/node_modules` and
    /// `~/work/web/node_modules` read as `api` and `web`.
    ///
    /// A single path has nothing to be told apart from, so it keeps its
    /// whole name.
    static func names(for paths: [String]) -> [String: String] {
        guard paths.count > 1 else {
            return paths.reduce(into: [:]) { result, path in
                result[path] = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
        }
        let parts = paths.map { $0.split(separator: "/").map(String.init) }
        guard let first = parts.first, let shortest = parts.map(\.count).min() else { return [:] }

        var shared = 0
        while shared < shortest - 1, parts.allSatisfy({ $0[shared] == first[shared] }) {
            shared += 1
        }
        let sharedLast = parts.allSatisfy { $0.last == first.last }

        var result: [String: String] = [:]
        for (path, components) in zip(paths, parts) {
            var tail = Array(components[shared...])
            if sharedLast, tail.count > 1 { tail.removeLast() }
            result[path] = tail.isEmpty
                ? (components.last ?? path)
                : tail.joined(separator: "/")
        }
        return result
    }
}

// MARK: - Placeholder

/// What a screen shows while it has nothing to show: one sentence, and the
/// action that would change that.
struct Placeholder: View {
    let message: LocalizedStringResource
    var detail: String?
    var action: (title: LocalizedStringResource, run: () -> Void)?

    var body: some View {
        HairBox(padding: EdgeInsets(top: 28, leading: 24, bottom: 28, trailing: 24)) {
            VStack(spacing: 10) {
                Text(message)
                    .font(Face.text(13, 500))
                    .foregroundStyle(Tone.ink)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(Face.text(11))
                        .foregroundStyle(Tone.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                if let action {
                    Button(action: action.run) { Text(action.title) }
                        .buttonStyle(.primaryAction)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}
