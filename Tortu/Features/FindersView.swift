import AppKit
import FindersKit
import Foundation
import ScanCore
import SwiftUI

/// The Finders.
///
/// Three tools that look for things the rules cannot know about: files that
/// are merely large, files that exist twice, and applications that are still
/// installed but have not been opened in months. Everything these remove goes
/// to the Trash, because unlike a build cache these are things a person made.
struct FindersView: View {
    /// Owned by the window: a walk of a home folder takes minutes and must
    /// not start over every time the sidebar moves away and back.
    let controller: FindersController

    @Environment(Preferences.self) private var preferences

    var body: some View {
        ScreenBody(bottom: 16) {
            ScreenHeader(title: "finders.title", subtitle: subtitle)
            tabs
            content
            if showsFooter { footer }
        }
        .onAppear {
            if !controller.hasChosenRoot {
                controller.root = preferences.scanRoots.first ?? NSHomeDirectory()
            }
            // The first tool is a directory walk and starts on its own. The
            // other two are not: hashing every file to find duplicates, and
            // measuring every application, are both expensive enough that
            // they should happen because the user asked.
            if case .idle = controller.phase, controller.mode == .largeFiles,
               !controller.hasRun {
                controller.run()
            }
        }
    }

    private var subtitle: String {
        if case let .duplicates(groups) = controller.phase, !groups.isEmpty {
            return String(localized: "finders.subtitle.groups \(groups.count)")
        }
        return ""
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 10) {
            ForEach(FindersController.Mode.allCases) { mode in
                Button {
                    controller.mode = mode
                    controller.run()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(for: mode))
                            .font(Face.text(13, 600))
                            .foregroundStyle(controller.mode == mode ? Tone.acct : Tone.ink)
                        Text(verbatim: summary(for: mode))
                            .font(Face.text(11))
                            .foregroundStyle(Tone.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                            .fill(controller.mode == mode ? Tone.tint : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                            .strokeBorder(
                                controller.mode == mode ? Tone.acc : Tone.line,
                                lineWidth: Metric.hairline
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(controller.mode == mode ? [.isSelected] : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func title(for mode: FindersController.Mode) -> LocalizedStringResource {
        switch mode {
        case .largeFiles: "finders.large.title"
        case .duplicates: "finders.duplicates.title"
        case .applications: "finders.applications.title"
        }
    }

    /// What each tab found, or what it is for before it has been run. The
    /// numbers only appear once that tool has actually looked.
    private func summary(for mode: FindersController.Mode) -> String {
        guard controller.mode == mode else {
            return String(localized: placeholderSummary(for: mode))
        }
        switch controller.phase {
        case let .largeFiles(files):
            return String(
                localized: "finders.large.summary \(files.count) \(Figure.bytes(files.reduce(ByteCount.zero) { $0 + $1.size }).joined)"
            )
        case let .duplicates(groups):
            let reclaimable = groups.reduce(ByteCount.zero) { $0 + $1.reclaimableUpperBound }
            return String(
                localized: "finders.duplicates.summary \(groups.count) \(Figure.bytes(reclaimable).joined)"
            )
        case let .applications(plans):
            let stale = plans.filter { isStale($0) }.count
            return String(
                localized: "finders.applications.summary \(plans.count) \(stale)"
            )
        default:
            return String(localized: placeholderSummary(for: mode))
        }
    }

    private func placeholderSummary(for mode: FindersController.Mode) -> LocalizedStringResource {
        switch mode {
        case .largeFiles: "finders.large.about"
        case .duplicates: "finders.duplicates.about"
        case .applications: "finders.applications.about"
        }
    }

    /// Six months without a trace is the point at which an application is
    /// worth asking about.
    private func isStale(_ plan: UninstallPlan) -> Bool {
        guard let trace = plan.application.lastTrace else { return true }
        return Date.now.timeIntervalSince(trace) > 180 * 86_400
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            Placeholder(
                message: "finders.idle",
                action: (title: "finders.run", run: { controller.run() })
            )
        case let .working(progress):
            working(progress)
        case let .failed(message):
            Placeholder(
                message: "finders.failed",
                detail: message,
                action: (title: "finders.run", run: { controller.run() })
            )
        case let .largeFiles(files):
            largeFiles(files)
        case let .duplicates(groups):
            duplicates(groups)
        case let .applications(plans):
            applications(plans)
        }
    }

    /// Each search reads out the measure it actually has: the two file
    /// searches walk a tree and report what they have walked, the
    /// application survey knows its total and reports a fraction of it.
    @ViewBuilder
    private func working(_ progress: FindersController.Progress?) -> some View {
        let isApplications = controller.mode == .applications
        WorkingBox(
            title: isApplications ? "finders.working.applications" : "finders.working",
            figures: isApplications
                ? [
                    WorkingFigure(
                        "working.applications",
                        Figure.Measure(
                            value: Figure.count(progress?.entriesSeen ?? 0),
                            unit: ""
                        )
                    ),
                    WorkingFigure("working.measured", Figure.bytes(progress?.bytesAccounted ?? .zero)),
                ]
                : [
                    WorkingFigure(
                        "working.entries",
                        Figure.Measure(
                            value: Figure.count(progress?.entriesSeen ?? 0),
                            unit: ""
                        )
                    ),
                    WorkingFigure("working.measured", Figure.bytes(progress?.bytesAccounted ?? .zero)),
                ],
            detail: progress.map {
                isApplications ? $0.currentPath : shortPath($0.currentPath)
            } ?? shortPath(controller.root),
            fraction: progress?.fraction,
            started: controller.startedAt,
            stop: { controller.cancel() }
        ) {
            switch controller.mode {
            case .largeFiles:
                SkeletonList(
                    columns: [.flexible(1), .fixed(110), .fixed(90)],
                    cells: [.lines(0.55), .line(0.75), .number(0.7)],
                    rows: 8,
                    height: 38
                )
            case .duplicates:
                SkeletonList(
                    columns: [.flexible(1), .fixed(90)],
                    cells: [.lines(0.6), .number(0.75)],
                    rows: 4,
                    height: 72,
                    style: .cards
                )
            case .applications:
                SkeletonList(
                    columns: [.fixed(24), .flexible(1), .fixed(110), .fixed(90)],
                    cells: [.check, .lines(0.5), .line(0.75), .number(0.7)],
                    rows: 8,
                    height: 38
                )
            }
        }
    }

    private func largeFiles(_ files: [FoundFile]) -> some View {
        listBox {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                if index > 0 { Hairline() }
                ColumnRow(
                    columns: [.flexible(1), .fixed(110), .fixed(90)],
                    spacing: 12
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: file.name)
                            .font(Face.text(12.5, 600))
                            .foregroundStyle(Tone.ink)
                            .lineLimit(1)
                        Text(verbatim: shortPath(file.path))
                            .font(Face.text(11))
                            .foregroundStyle(Tone.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(verbatim: file.modified.formatted(date: .abbreviated, time: .omitted))
                        .font(Face.text(11))
                        .foregroundStyle(Tone.muted)
                    Text(verbatim: Figure.bytes(file.size).joined)
                        .font(Face.display(13, 600))
                        .foregroundStyle(Tone.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file.path)])
                }
            }
        }
    }

    private func duplicates(_ groups: [DuplicateGroup]) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(groups) { group in
                    DuplicateGroupBox(
                        group: group,
                        keptPath: keptPath(in: group),
                        choose: { path in
                            controller.keep(path, in: group.id)
                            syncSelection(groups)
                        }
                    )
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { syncSelection(groups) }
        .onChange(of: groups.map(\.id)) { _, _ in syncSelection(groups) }
    }

    private func applications(_ plans: [UninstallPlan]) -> some View {
        listBox {
            ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                if index > 0 { Hairline() }
                ColumnRow(
                    columns: [.fixed(24), .flexible(1), .fixed(110), .fixed(90)],
                    spacing: 12
                ) {
                    Button { controller.toggle(plan.application.path) } label: {
                        CheckBox(isOn: controller.isSelected(plan.application.path))
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: plan.application.name)
                            .font(Face.text(12.5, 600))
                            .foregroundStyle(Tone.ink)
                            .lineLimit(1)
                        Text(verbatim: String(
                            localized: "finders.applications.leftovers \(plan.leftovers.count)"
                        ))
                        .font(Face.text(11))
                        .foregroundStyle(Tone.muted)
                    }

                    Group {
                        if let trace = plan.application.lastTrace {
                            Text(verbatim: trace.formatted(date: .abbreviated, time: .omitted))
                                .font(Face.text(11))
                                .foregroundStyle(isStale(plan) ? Tone.sec : Tone.muted)
                        } else {
                            Badge("finders.applications.noTrace")
                        }
                    }

                    Text(verbatim: Figure.bytes(plan.totalSize).joined)
                        .font(Face.display(13, 600))
                        .foregroundStyle(Tone.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
            }
        }
    }

    private func listBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) { content() }
                .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.boxRadius, style: .continuous)
                .strokeBorder(Tone.line, lineWidth: Metric.hairline)
        )
    }

    // MARK: Selection

    /// The newest copy is kept unless the user says otherwise, because the
    /// newest is the one most likely to be the one in use.
    private func keptPath(in group: DuplicateGroup) -> String? {
        controller.kept[group.id] ?? group.files.max(by: { $0.modified < $1.modified })?.path
    }

    private func syncSelection(_ groups: [DuplicateGroup]) {
        var selection: Set<String> = []
        for group in groups {
            let keep = keptPath(in: group)
            for file in group.files where file.path != keep {
                selection.insert(file.path)
            }
        }
        controller.setSelection(selection)
    }

    // MARK: Footer

    private var showsFooter: Bool {
        switch controller.phase {
        case .duplicates, .applications: true
        default: false
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BigNumber(
                    measure: Figure.bytes(controller.selectedSize), size: 22, unitSize: 13
                )
                Note(verbatim: footerDetail).tinted(Tone.sec).sized(12)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    let urls = controller.selectedPathsForReveal.map { URL(filePath: $0) }
                    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                } label: {
                    Text("finders.reveal")
                }
                .buttonStyle(.secondaryAction)

                Button { controller.trashSelected() } label: { Text("finders.trash") }
                    .buttonStyle(.primaryAction)
                    .disabled(controller.selectedSize == .zero)
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

    private var footerDetail: String {
        if case let .duplicates(groups) = controller.phase {
            let removing = groups.flatMap(\.files).filter { controller.isSelected($0.path) }.count
            return String(
                localized: "finders.footer.duplicates \(removing) \(groups.count)"
            )
        }
        if case let .applications(plans) = controller.phase {
            let chosen = plans.filter { controller.isSelected($0.application.path) }.count
            return String(localized: "finders.footer.applications \(chosen)")
        }
        return ""
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Duplicate group

private struct DuplicateGroupBox: View {
    let group: DuplicateGroup
    let keptPath: String?
    let choose: (String) -> Void

    var body: some View {
        HairBox(padding: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: group.files.first?.name ?? "")
                        .font(Face.text(13, 600))
                        .foregroundStyle(Tone.ink)
                        .lineLimit(1)
                    Note(verbatim: String(
                        localized: "finders.duplicates.group \(group.files.count) \(Figure.bytes(group.files.first?.size ?? .zero).joined)"
                    ))
                    Spacer(minLength: 8)
                    Text(verbatim: String(
                        localized: "finders.duplicates.reclaimable \(Figure.bytes(group.reclaimableUpperBound).joined)"
                    ))
                    .font(Face.text(11.5, 600))
                    .foregroundStyle(Tone.acct)
                }

                ForEach(group.files) { file in
                    let isKept = file.path == keptPath
                    Button { choose(file.path) } label: {
                        ColumnRow(
                            columns: [.fixed(18), .flexible(1), .fixed(90), .fixed(70), .fixed(70)],
                            spacing: 10
                        ) {
                            Radio(isOn: isKept)
                            Text(verbatim: file.path.replacingOccurrences(
                                of: NSHomeDirectory(), with: "~"
                            ))
                            .font(Face.text(11.5))
                            .foregroundStyle(isKept ? Tone.ink : Tone.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)

                            Text(verbatim: file.modified.formatted(
                                date: .abbreviated, time: .omitted
                            ))
                            .font(Face.text(11))
                            .foregroundStyle(Tone.muted)

                            Text(verbatim: Figure.bytes(file.size).joined)
                                .font(Face.display(11.5, 600))
                                .foregroundStyle(isKept ? Tone.ink : Tone.muted)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(isKept ? "finders.duplicates.kept" : "finders.duplicates.removed")
                                .font(Face.text(9.5, 600))
                                .tracking(0.76)
                                .textCase(nil)
                                .foregroundStyle(isKept ? Tone.acct : Tone.muted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A radio button. Drawn, like the checkbox, so that it can take the accent.
private struct Radio: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? Tone.acc : Tone.b2, lineWidth: isOn ? 4 : 1)
            .frame(width: 13, height: 13)
    }
}

private extension FindersController {
    /// Paths to show in Finder: whatever is currently ticked.
    var selectedPathsForReveal: [String] {
        Array(selectedPaths.prefix(20))
    }
}
