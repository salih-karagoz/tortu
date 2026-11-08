import AppKit
import CleanerKit
import Foundation
import RulesEngine
import ScanCore
import SwiftUI

/// The Explorer.
///
/// A size tree, with the two things a size tree usually gets wrong called out
/// on the row itself: a directory on another filesystem is marked rather than
/// counted, and a hard link that has already been counted elsewhere shows its
/// size in brackets. Both exist because a tool that silently adds those to
/// the total tells the user to delete something that will free nothing.
struct ExplorerView: View {
    /// Owned by the window, not by this screen: a count of a home folder
    /// takes minutes, and SwiftUI destroys a screen's own state every time
    /// the sidebar moves away from it.
    @Bindable var controller: ScanController
    let onOpenRule: () -> Void

    @Environment(CleanupController.self) private var cleanup
    @Environment(Preferences.self) private var preferences

    private static let columns: [ColumnRow.Column] = [
        .flexible(1), .fixed(170), .fixed(74), .fixed(60), .fixed(176),
    ]

    var body: some View {
        ScreenBody(bottom: 16) {
            ScreenHeader(title: "explorer.title", subtitle: subtitle) {
                HStack(spacing: 12) {
                    Button { controller.sedimentOnly.toggle() } label: {
                        HStack(spacing: 6) {
                            CheckBox(isOn: controller.sedimentOnly)
                            Text("explorer.sedimentOnly")
                                .font(Face.text(12))
                                .foregroundStyle(Tone.sec)
                        }
                    }
                    .buttonStyle(.plain)

                    SegmentPicker(
                        options: [
                            (value: false, title: String(localized: "explorer.sort.size")),
                            (value: true, title: String(localized: "explorer.sort.name")),
                        ],
                        selection: $controller.sortByName
                    )
                }
            }

            if let result = controller.result {
                breadcrumb(result)
                tree(result)
                footer(result)
            } else {
                content
            }
        }
        .onAppear {
            if !controller.hasChosenRoot {
                controller.rootPath = preferences.scanRoots.first ?? NSHomeDirectory()
            }
            // Counting is the whole purpose of this screen and reads nothing
            // it does not already have permission to read, so the first visit
            // starts it rather than asking. Only the first: a count that
            // finished is still on screen, and one the user stopped stays
            // stopped.
            if case .idle = controller.phase, !controller.hasRun {
                controller.start()
            }
        }
    }

    private var subtitle: String {
        guard let result = controller.result else { return "" }
        return String(
            localized: "explorer.subtitle \(Figure.bytes(result.root.totalSize).joined) \(Figure.count(result.entriesSeen))"
        ) + (controller.lastFinished.map {
            " · " + $0.formatted(date: .omitted, time: .shortened)
        } ?? "")
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            Placeholder(
                message: "explorer.idle",
                detail: shortPath(controller.rootPath),
                action: (title: "explorer.scan", run: { controller.start() })
            )
        case let .scanning(progress):
            // A count of a whole home folder takes a while, so the screen
            // reads out what it has counted so far and the directory it is
            // in, over the outline of the table it is about to fill.
            WorkingBox(
                title: "explorer.scanning",
                figures: [
                    WorkingFigure(
                        "working.entries",
                        Figure.Measure(
                            value: Figure.count(progress?.entriesSeen ?? 0),
                            unit: ""
                        )
                    ),
                    WorkingFigure(
                        "working.measured",
                        Figure.bytes(progress?.bytesAccounted ?? .zero)
                    ),
                ],
                detail: progress.map { shortPath($0.currentPath) },
                started: controller.startedAt,
                stop: { controller.cancel() }
            ) {
                SkeletonList(
                    columns: Self.columns,
                    cells: [.line(0.6), .bar, .number(0.55), .number(0.4), .blank],
                    rows: 12,
                    height: 26
                )
            }
        case let .failed(message):
            Placeholder(
                message: "explorer.failed",
                detail: message,
                action: (title: "explorer.scan", run: { controller.start() })
            )
        case .finished:
            EmptyView()
        }
    }

    // MARK: Breadcrumb

    private func breadcrumb(_ result: ScanResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(crumbs(result).enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Text(verbatim: "›")
                            .font(Face.text(12))
                            .foregroundStyle(Tone.b2)
                    }
                    Text(verbatim: crumb)
                        .font(Face.text(12, index == crumbs(result).count - 1 ? 600 : 400))
                        .foregroundStyle(index == crumbs(result).count - 1 ? Tone.ink : Tone.sec)
                }
            }
            Spacer(minLength: 12)
            Note(verbatim: String(
                localized: "explorer.barScale \(Figure.bytes(result.root.totalSize).joined)"
            ))
            .lineLimit(1)
            .fixedSize()
        }
    }

    private func crumbs(_ result: ScanResult) -> [String] {
        let path = controller.selected ?? result.root.path
        return path.split(separator: "/").map(String.init)
    }

    // MARK: Tree

    private func tree(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows(result)) { row in
                        if row.depth == 0, row.id != visibleRoots(result).first?.node.path {
                            Hairline()
                        }
                        ExplorerRow(
                            node: row.node,
                            depth: row.depth,
                            columns: Self.columns,
                            scale: result.root.totalSize,
                            coverage: coverage[row.node.path],
                            isExpanded: controller.expanded.contains(row.node.path),
                            isSelected: controller.selected == row.node.path,
                            toggle: { toggle(row.node) },
                            select: { controller.selected = row.node.path }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
    }

    private struct Row: Identifiable {
        let node: ScanNode
        let depth: Int
        var id: String { node.path }
    }

    private func visibleRoots(_ result: ScanResult) -> [Row] {
        sorted(result.root.children).filter(passes).map { Row(node: $0, depth: 0) }
    }

    private func rows(_ result: ScanResult) -> [Row] {
        visibleRoots(result).flatMap { descend($0.node, depth: 0) }
    }

    private func descend(_ node: ScanNode, depth: Int) -> [Row] {
        var out = [Row(node: node, depth: depth)]
        guard controller.expanded.contains(node.path) else { return out }
        for child in sorted(node.children) where passes(child) {
            out.append(contentsOf: descend(child, depth: depth + 1))
        }
        return out
    }

    private func sorted(_ nodes: [ScanNode]) -> [ScanNode] {
        controller.sortByName
            ? nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : nodes.sorted { $0.totalSize > $1.totalSize }
    }

    /// With the filter on, a row survives only if a rule covers it or
    /// something beneath it, so the tree collapses to the parts the app
    /// believes it can act on.
    private func passes(_ node: ScanNode) -> Bool {
        guard controller.sedimentOnly else { return true }
        if coverage[node.path] != nil { return true }
        return coveredPrefixes.contains { $0.hasPrefix(node.path + "/") }
    }

    private func toggle(_ node: ScanNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        if controller.expanded.contains(node.path) {
            controller.expanded.remove(node.path)
        } else {
            controller.expanded.insert(node.path)
        }
    }

    // MARK: Rule coverage

    /// Which rule, if any, claims each path. Built from the current plan, so
    /// a path only reads as sediment once the rules have actually been
    /// measured against this machine.
    private var coverage: [String: RuleCoverage] {
        guard let plan = cleanup.plan else { return [:] }
        var map: [String: RuleCoverage] = [:]
        for evaluation in plan.evaluations {
            let locked = evaluation.blockingApplications.first
            for candidate in evaluation.candidates + evaluation.kept {
                map[candidate.path] = RuleCoverage(
                    ruleName: evaluation.rule.name.resolved(),
                    ruleID: evaluation.rule.id,
                    blockedBy: locked
                )
            }
        }
        return map
    }

    private var coveredPrefixes: Set<String> { Set(coverage.keys) }

    // MARK: Footer

    private func footer(_ result: ScanResult) -> some View {
        let node = find(controller.selected, in: result.root)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: node.map { shortPath($0.path) } ?? shortPath(result.root.path))
                    .font(Face.text(12.5, 600))
                    .foregroundStyle(Tone.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: footerDetail(node ?? result.root))
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(filePath: node?.path ?? result.root.path),
                    ])
                } label: {
                    Text("explorer.revealInFinder")
                }
                .buttonStyle(.secondaryAction)

                Button(action: onOpenRule) { Text("explorer.openInCleanup") }
                    .buttonStyle(.primaryAction)
                    .disabled(node.flatMap { coverage[$0.path] } == nil)
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
    }

    private func footerDetail(_ node: ScanNode) -> String {
        var parts = [
            Figure.bytes(node.totalSize).joined,
            String(localized: "explorer.footer.items \(node.fileCount)"),
        ]
        if let rule = coverage[node.path] {
            parts.append(String(localized: "explorer.footer.rule \(rule.ruleName)"))
        }
        return parts.joined(separator: " · ")
    }

    private func find(_ path: String?, in node: ScanNode) -> ScanNode? {
        guard let path else { return nil }
        if node.path == path { return node }
        guard path.hasPrefix(node.path) else { return nil }
        for child in node.children {
            if let hit = find(path, in: child) { return hit }
        }
        return nil
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

struct RuleCoverage {
    let ruleName: String
    let ruleID: String
    let blockedBy: String?
}

// MARK: - Row

private struct ExplorerRow: View {
    let node: ScanNode
    let depth: Int
    let columns: [ColumnRow.Column]
    let scale: ByteCount
    let coverage: RuleCoverage?
    let isExpanded: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let select: () -> Void

    private var isLocked: Bool { coverage?.blockedBy != nil }
    private var isCovered: Bool { coverage != nil && !isLocked }

    var body: some View {
        ColumnRow(columns: columns) {
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(depth) * 18, height: 1)
                if node.isDirectory, !node.children.isEmpty {
                    Button(action: toggle) { Chevron(isOpen: isExpanded) }
                        .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 10, height: 10)
                }
                Text(verbatim: node.name)
                    .font(Face.text(12, isCovered ? 600 : 400))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            TrackBar(fraction: fraction, fill: barColour)
                .padding(.trailing, 10)

            Text(verbatim: sizeText)
                .font(Face.display(12, 600))
                .foregroundStyle(sizeColour)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(verbatim: node.isBoundary ? "—" : Figure.count(node.fileCount))
                .font(Face.text(11))
                .foregroundStyle(Tone.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)

            note
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(isSelected ? Tone.tint : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    @ViewBuilder
    private var note: some View {
        if node.isBoundary {
            Badge("explorer.badge.otherFilesystem")
        } else if node.sharesStorage {
            HStack(spacing: 6) {
                Badge("explorer.badge.alreadyCounted")
                Text("explorer.badge.hardLink")
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                    .lineLimit(1)
            }
        } else if let blocker = coverage?.blockedBy {
            HStack(spacing: 6) {
                Badge("cleanup.badge.locked")
                Text(verbatim: blocker)
                    .font(Face.text(11))
                    .foregroundStyle(Tone.muted)
                    .lineLimit(1)
            }
        } else if let coverage {
            Text(verbatim: String(
                localized: "explorer.note.rule \(coverage.ruleName)"
            ).displayUppercase)
            .font(Face.text(10, 600))
            .tracking(0.8)
            .foregroundStyle(Tone.acct)
            .lineLimit(1)
            .truncationMode(.tail)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// A boundary and an already-counted hard link both contribute nothing to
    /// this total, so neither gets a bar.
    private var fraction: Double {
        guard !node.isBoundary, !node.sharesStorage, scale.rawValue > 0 else { return 0 }
        return Double(node.totalSize.rawValue) / Double(scale.rawValue)
    }

    private var sizeText: String {
        if node.isBoundary { return "—" }
        let measure = Figure.bytes(node.totalSize)
        // Brackets say "this is real, but it is already in the total above".
        return node.sharesStorage ? "(\(measure.joined))" : measure.joined
    }

    private var nameColor: Color {
        if isLocked || node.isBoundary || node.sharesStorage { return Tone.muted }
        return isCovered ? Tone.acct : Tone.ink
    }

    private var sizeColour: Color {
        if isLocked || node.isBoundary || node.sharesStorage { return Tone.muted }
        return isCovered ? Tone.acct : Tone.ink
    }

    private var barColour: Color {
        if isLocked || node.sharesStorage { return Tone.b2 }
        return isCovered ? Tone.acc : Tone.ink
    }
}
