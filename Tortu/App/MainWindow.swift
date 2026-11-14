import Entitlements
import MonitorKit
import ScanCore
import SwiftData
import SwiftUI

/// Named `SidebarSection` rather than `Section` so it does not shadow
/// SwiftUI's own `Section` anywhere else in the module.
enum SidebarSection: String, CaseIterable, Identifiable {
    case panel, activity, cleanup, explorer, finders, history, settings

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .panel: "sidebar.panel"
        case .activity: "sidebar.activity"
        case .cleanup: "sidebar.cleanup"
        case .explorer: "sidebar.explorer"
        case .finders: "sidebar.finders"
        case .history: "sidebar.history"
        case .settings: "sidebar.settings"
        }
    }
}

struct MainWindow: View {
    @Environment(VolumeMonitor.self) private var monitor
    @Environment(CleanupController.self) private var cleanup
    @Environment(Preferences.self) private var preferences
    @Environment(\.entitlements) private var entitlements
    @Environment(\.modelContext) private var context
    @Binding var selection: SidebarSection

    // The Explorer's count and the Finders' search take minutes, and SwiftUI
    // throws a screen's own state away the moment the sidebar moves off it.
    // So both live here, for as long as the window does, and the screens are
    // handed them: leaving a count and coming back finds it where it was
    // rather than starting the walk again. The Cleanup controller is already
    // held a level up, because the sidebar prints its rule count.
    @State private var scan = ScanController()
    @State private var finders = FindersController()
    // The live instrument keeps minutes of trace behind it, and it stops
    // reading the moment its screen goes away. Both belong to the window.
    @State private var activity = ActivityController()

    // The other two screens have no controller to keep their place in, and
    // their place is small enough not to be worth inventing one for.
    @State private var cleanupFilter = CleanupView.RuleFilter.all
    @State private var historyExpanded: Set<Date> = []

    #if DEBUG
    @State private var showsMenuBarPanel = false
    #endif

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
            detail
        }
        .background(Tone.bg)
        // The title bar is hidden but its safe area is not: without this the
        // whole window starts a title bar's height too low, which shows up as
        // a gap above the logotype and an off-measure top margin on every
        // screen. The strip deliberately runs underneath the traffic lights
        // and leaves them their own empty band.
        .ignoresSafeArea(.container, edges: .top)
        #if DEBUG
        // The menu bar panel lives in a window the app cannot open itself,
        // so for a snapshot it is drawn over this one.
        .overlay {
            if showsMenuBarPanel {
                MenuBarContent()
                    .shadow(color: Tone.shadow, radius: 24, y: 10)
            }
        }
        #endif
        .frame(
            minWidth: 880, idealWidth: Metric.windowWidth,
            minHeight: 580, idealHeight: Metric.windowHeight
        )
        // Every reading the monitor takes becomes a point in the series the
        // Panel draws. The recorder drops readings closer together than five
        // minutes, so opening and closing the window does not forge history.
        .onChange(of: monitor.lastUpdate) { _, _ in
            guard let stats = monitor.stats else { return }
            HistoryRecorder(context: context).recordVolume(stats)
            // Every reading is also the moment to ask whether a threshold
            // the user set has been crossed. Nothing is sent without
            // permission, and permission is asked for in Settings.
            guard entitlements.isUnlocked(.backgroundMonitoring) else { return }
            let names = Dictionary(
                cleanup.rules.map { ($0.id, $0.name.resolved()) },
                uniquingKeysWith: { first, _ in first }
            )
            Task {
                await ThresholdNotifier(context: context, preferences: preferences)
                    .check(stats, names: names)
            }
        }
        #if DEBUG
        .task {
            guard DebugSnapshot.directory != nil else { return }
            if DebugSnapshot.shouldScan {
                cleanup.analyse()
                while cleanup.isBusy {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            if DebugSnapshot.expandsRules, let plan = cleanup.plan {
                // The biggest rules whose path list is short enough to read
                // in one capture. A hash-bucketed cache matches hundreds and
                // would fill the window on its own.
                let openable = plan.evaluations
                    .filter { (2...20).contains($0.candidates.count) }
                    .sorted { $0.reclaimable > $1.reclaimable }
                cleanup.expandedRules = Set(openable.prefix(3).map(\.id))
                // Strike one path out, through the same call the checkbox
                // makes, so the capture shows a real struck-out row.
                if let rule = openable.first, rule.candidates.count > 2 {
                    cleanup.togglePath(rule.candidates[1].path, in: rule)
                }
            }
            await DebugSnapshot.run(
                select: { selection = $0 },
                showMenuBar: { showsMenuBarPanel = $0 },
                prepare: { section in
                    // Every screen's work now survives the sidebar, so a
                    // capture of the waiting state has to ask for it again.
                    switch section {
                    case .cleanup: cleanup.analyse()
                    case .explorer: scan.start()
                    case .finders: finders.run()
                    case .activity: activity.start()
                    default: break
                    }
                }
            )
        }
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .panel: PanelView()
        case .activity:
            ActivityView(controller: activity, onOpenSettings: { selection = .settings })
        case .cleanup:
            CleanupView(filter: $cleanupFilter)
        case .explorer:
            ExplorerView(controller: scan, onOpenRule: { selection = .cleanup })
        case .finders:
            FindersView(controller: finders)
        case .history: HistoryView(expanded: $historyExpanded)
        case .settings: SettingsView()
        }
    }
}

/// The fixed two hundred point strip down the left.
///
/// A plain `HStack` rather than `NavigationSplitView`, because the design
/// gives the strip a fixed width that the user cannot drag, a footer pinned
/// to the bottom and rows that are not list rows. Every one of those is a
/// fight with the split view, and winning the fight leaves a split view that
/// still behaves like one in ways the design does not want.
private struct Sidebar: View {
    @Environment(VolumeMonitor.self) private var monitor
    @Environment(CleanupController.self) private var cleanup
    @Environment(\.entitlements) private var entitlements
    @Binding var selection: SidebarSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window draws its own traffic lights over this space; the
            // app only has to leave it empty.
            Color.clear.frame(height: 50)

            HStack(spacing: 8) {
                AppMark(size: 26)
                Text(verbatim: "Tortu")
                    .font(Face.display(17, 700))
                    .tracking(-0.34)
                    .foregroundStyle(Tone.ink)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)

            ForEach(SidebarSection.allCases) { section in
                NavRow(
                    section: section,
                    isActive: selection == section,
                    trailing: trailing(for: section)
                ) {
                    selection = section
                }
            }

            Spacer(minLength: 12)
            footer
        }
        .frame(width: Metric.sidebarWidth)
        .padding(.bottom, 18)
        .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
    }

    /// The rule count beside Cleanup, and a word beside anything a licence
    /// is needed for. A paid section is shown and marked rather than hidden:
    /// a row that appears only after buying cannot be decided about.
    private func trailing(for section: SidebarSection) -> String? {
        switch section {
        case .cleanup:
            cleanup.ruleCount > 0 ? Figure.count(cleanup.ruleCount) : nil
        case .activity:
            entitlements.isUnlocked(.liveActivity)
                ? nil : String(localized: "badge.paid").displayUppercase
        default:
            nil
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monitor.volumeName)
                    .font(Face.text(12))
                    .foregroundStyle(Tone.sec)
                Spacer(minLength: 6)
                Text(Figure.percent(monitor.usedFraction))
                    .font(Face.display(12, 600))
                    .foregroundStyle(Tone.ink)
            }
            SplitBar(
                otherFraction: max(monitor.usedFraction - sedimentFraction, 0),
                sedimentFraction: sedimentFraction
            )
            Text(cadenceText)
                .font(Face.text(11))
                .foregroundStyle(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .overlay(alignment: .top) { Hairline() }
    }

    /// How much of the whole volume the app currently believes is sediment.
    /// Zero until an analysis has run, which is honest: before then the app
    /// does not know.
    private var sedimentFraction: Double {
        guard let stats = monitor.stats, stats.total.rawValue > 0,
              let plan = cleanup.plan else { return 0 }
        return Double(plan.estimatedReclaim.rawValue) / Double(stats.total.rawValue)
    }

    private var cadenceText: String {
        guard let last = monitor.lastUpdate else {
            return String(localized: "sidebar.cadence.waiting")
        }
        return String(
            localized: "sidebar.cadence \(monitor.cadenceDescription) \(last.formatted(date: .omitted, time: .shortened))"
        )
    }
}

private struct NavRow: View {
    let section: SidebarSection
    let isActive: Bool
    let trailing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Dot(color: isActive ? Tone.acc : .clear)
                Text(section.title)
                    .font(Face.text(13, isActive ? 600 : 500))
                    .foregroundStyle(isActive ? Tone.ink : Tone.sec)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(Face.display(12, 600))
                        .foregroundStyle(Tone.muted)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: Metric.navRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Tone.soft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// The header every screen opens with: its name, and one line of provenance
/// on the right saying when the figures below it were measured.
struct ScreenHeader<Trailing: View>: View {
    let title: LocalizedStringResource
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ScreenTitle(title)
                if let subtitle {
                    Note(verbatim: subtitle).sized(12)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: LocalizedStringResource, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The padding every screen's content sits in.
struct ScreenBody<Content: View>: View {
    var bottom: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .padding(.bottom, bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
