import AppKit
import Entitlements
import Foundation
import ScanCore
import SwiftUI
import UserNotifications

/// The Settings screen.
///
/// Two columns of hairline boxes. Every control here changes what the Cleanup
/// screen will do on its next run — the protections are applied to the rules
/// before they are measured, and the exclusions to the results afterwards —
/// so nothing on this screen is a preference the app then ignores.
struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(\.entitlements) private var entitlements
    @Environment(VolumeMonitor.self) private var monitor

    var body: some View {
        @Bindable var preferences = preferences

        ScreenBody {
            ScreenHeader(title: "settings.title")

            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        scanRoots($preferences)
                        excludedPaths($preferences)
                        protections($preferences)
                        appearance($preferences)
                        language($preferences)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        measurement($preferences)
                        thresholds($preferences)
                        helper
                        licence
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Scan roots

    private func scanRoots(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.roots.label") {
            ForEach(preferences.wrappedValue.scanRoots, id: \.self) { root in
                ColumnRow(columns: [.fixed(20), .flexible(1), .fixed(74)], spacing: 8) {
                    CheckBox(isOn: true)
                    Text(verbatim: shortPath(root))
                        .font(Face.text(12))
                        .foregroundStyle(Tone.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        preferences.wrappedValue.scanRoots.removeAll { $0 == root }
                    } label: {
                        Text("settings.remove")
                            .font(Face.text(11.5))
                            .foregroundStyle(Tone.sec)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(preferences.wrappedValue.scanRoots.count <= 1)
                }
                .frame(height: 26)
            }
            Button {
                if let path = chooseDirectory(),
                   !preferences.wrappedValue.scanRoots.contains(path) {
                    preferences.wrappedValue.scanRoots.append(path)
                }
            } label: {
                Text("settings.roots.add")
            }
            .buttonStyle(.secondaryAction)
            .padding(.top, 2)
        }
    }

    // MARK: Excluded paths

    private func excludedPaths(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.excluded.label") {
            if preferences.wrappedValue.excludedPaths.isEmpty {
                Note("settings.excluded.empty")
            }
            ForEach(preferences.wrappedValue.excludedPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Text(verbatim: shortPath(path))
                        .font(Face.text(12))
                        .foregroundStyle(Tone.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        preferences.wrappedValue.excludedPaths.removeAll { $0 == path }
                    } label: {
                        Text("settings.remove")
                            .font(Face.text(11.5))
                            .foregroundStyle(Tone.sec)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 26)
            }
            Button {
                if let path = chooseDirectory(),
                   !preferences.wrappedValue.excludedPaths.contains(path) {
                    preferences.wrappedValue.excludedPaths.append(path)
                }
            } label: {
                Text("settings.excluded.add")
            }
            .buttonStyle(.secondaryAction)
            .padding(.top, 2)
        }
    }

    // MARK: Protections

    private func protections(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.protect.label") {
            SwitchRow(
                title: "settings.protect.flutter",
                isOn: preferences.keepNewestFlutterBuilds
            )
            Hairline()
            SwitchRow(
                title: "settings.protect.openApps",
                isOn: preferences.lockOpenApplicationCaches
            )
            Hairline()
            SwitchRow(
                title: "settings.protect.simulators",
                isOn: preferences.leaveSimulatorRuntimes
            )
            Hairline()
            SwitchRow(
                title: "settings.protect.recent",
                isOn: preferences.skipRecentlyModified
            )
        }
    }

    // MARK: Appearance

    private func appearance(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.appearance.label") {
            SegmentPicker(
                options: AppearanceChoice.allCases.map {
                    (value: $0, title: String(localized: $0.title))
                },
                selection: preferences.appearance
            )
            Note("settings.appearance.note")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Language

    private func language(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.language.label") {
            SegmentPicker(
                options: LanguageChoice.allCases.map { (value: $0, title: $0.title) },
                selection: preferences.language
            )
            if preferences.wrappedValue.needsRestartForLanguage {
                HStack(spacing: 10) {
                    Note("settings.language.restartNote")
                        .tinted(Tone.sec)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { LanguageChoice.restart() } label: {
                        Text("settings.language.restart")
                    }
                    .buttonStyle(.secondaryAction)
                }
            } else {
                Note("settings.language.note")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Measurement

    private func measurement(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.measurement.label") {
            SegmentPicker(
                options: MeasurementCadence.allCases.map {
                    (value: $0, title: String(localized: $0.title))
                },
                selection: preferences.cadence
            )
            SwitchRow(title: "settings.measurement.battery", isOn: preferences.throttleOnBattery)
                .padding(.top, 2)
            Note("settings.measurement.note")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Thresholds

    private func thresholds(_ preferences: Bindable<Preferences>) -> some View {
        SettingsBox(label: "settings.thresholds.label") {
            ThresholdRow(
                title: "settings.thresholds.free",
                unit: "GB",
                value: preferences.freeSpaceThresholdGB,
                fractionDigits: 0
            )
            ThresholdRow(
                title: "settings.thresholds.days",
                unit: String(localized: "unit.day"),
                value: preferences.daysToFullThreshold,
                fractionDigits: 0
            )
            ThresholdRow(
                title: "settings.thresholds.growth",
                unit: "GB / " + String(localized: "unit.day"),
                value: preferences.growthThresholdGBPerDay,
                fractionDigits: 1
            )
            NotificationPermission(
                isUnlocked: entitlements.isUnlocked(.backgroundMonitoring)
            )
            .padding(.top, 2)
        }
    }

    // MARK: Helper

    /// The privileged helper is not installed yet, and the screen says so
    /// rather than showing a state it cannot verify.
    private var helper: some View {
        SettingsBox(label: "settings.helper.label") {
            HStack(spacing: 8) {
                Dot(color: Tone.b2, size: 7)
                Text("settings.helper.absent")
                    .font(Face.text(12.5))
                    .foregroundStyle(Tone.ink)
            }
            Note("settings.helper.note")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Licence

    /// The software licence, not a bought one. There is nothing to buy, and a
    /// settings screen that implied otherwise would be exactly the kind of
    /// claim the rest of this screen exists to avoid.
    private var licence: some View {
        SettingsBox(label: "settings.licence.label") {
            Text("settings.licence.open")
                .font(Face.text(12.5, 600))
                .foregroundStyle(Tone.ink)
            Note("settings.licence.openNote")
                .fixedSize(horizontal: false, vertical: true)
            Button { openSource() } label: { Text("settings.licence.source") }
                .buttonStyle(.secondaryAction)
                .padding(.top, 2)
        }
    }

    // MARK: Helpers

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }

    /// Opens the repository. The application is that repository built: there
    /// is no capability in one that is missing from the other.
    private func openSource() {
        guard let url = URL(string: "https://github.com/salih-karagoz/tortu") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Pieces

/// One section of the Settings screen.
private struct SettingsBox<Content: View>: View {
    let label: LocalizedStringResource
    @ViewBuilder var content: Content

    var body: some View {
        HairBox(padding: EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14)) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(label)
                content
            }
        }
    }
}

/// A number the user types, with its unit beside it.
private struct ThresholdRow: View {
    let title: LocalizedStringResource
    let unit: String
    @Binding var value: Double
    var fractionDigits: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Face.text(12.5))
                .foregroundStyle(Tone.ink)
            Spacer(minLength: 8)
            TextField(
                "",
                value: $value,
                format: .number.precision(.fractionLength(fractionDigits))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(Face.display(12.5, 600))
            .foregroundStyle(Tone.ink)
            .frame(width: 44)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: Metric.segmentRadius, style: .continuous)
                    .strokeBorder(Tone.b2, lineWidth: Metric.hairline)
            )
            Text(verbatim: unit)
                .font(Face.text(11.5))
                .foregroundStyle(Tone.muted)
                .frame(width: 56, alignment: .leading)
        }
        .frame(height: 26)
    }
}

/// Whether Tortu may send the notifications the thresholds above describe.
///
/// Asking happens here, next to the setting it is for, rather than at launch:
/// a permission prompt that arrives before the user has expressed any wish
/// is the thing that teaches people to refuse them.
private struct NotificationPermission: View {
    let isUnlocked: Bool

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Dot(color: status == .authorized ? Tone.acc : Tone.b2, size: 7)
                Text(state)
                    .font(Face.text(12.5))
                    .foregroundStyle(Tone.ink)
            }
            Note(note)
                .fixedSize(horizontal: false, vertical: true)
            if isUnlocked, status == .notDetermined {
                Button {
                    isAsking = true
                    Task {
                        status = await ThresholdNotifier.requestAuthorisation()
                        isAsking = false
                    }
                } label: { Text("settings.thresholds.allow") }
                .buttonStyle(.secondaryAction)
                .disabled(isAsking)
                .padding(.top, 2)
            }
        }
        .task { status = await ThresholdNotifier.authorisation() }
    }

    private var state: LocalizedStringResource {
        guard isUnlocked else { return "settings.thresholds.locked" }
        return switch status {
        case .authorized, .provisional, .ephemeral: "settings.thresholds.on"
        case .denied: "settings.thresholds.denied"
        default: "settings.thresholds.off"
        }
    }

    private var note: LocalizedStringResource {
        guard isUnlocked else { return "settings.thresholds.lockedNote" }
        return switch status {
        case .authorized, .provisional, .ephemeral: "settings.thresholds.onNote"
        case .denied: "settings.thresholds.deniedNote"
        default: "settings.thresholds.offNote"
        }
    }
}
