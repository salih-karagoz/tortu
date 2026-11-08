import Foundation
import Observation
import ScanCore

/// How often the app measures the volume on its own.
///
/// The design puts this in Settings as four segments, and the sidebar prints
/// the chosen one under the disk bar, so the user can always see the cadence
/// the numbers above it were produced at.
enum MeasurementCadence: String, CaseIterable, Identifiable, Sendable {
    case off
    case hourly
    case quarterHour
    case always

    static let defaultsKey = "backgroundMeasurement"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .off: "cadence.off"
        case .hourly: "cadence.hourly"
        case .quarterHour: "cadence.quarterHour"
        case .always: "cadence.always"
        }
    }

    /// The phrase the sidebar prints, e.g. "measured every 15 min".
    var sentence: LocalizedStringResource {
        switch self {
        case .off: "cadence.sentence.off"
        case .hourly: "cadence.sentence.hourly"
        case .quarterHour: "cadence.sentence.quarterHour"
        case .always: "cadence.sentence.always"
        }
    }

    var interval: Duration? {
        switch self {
        case .off: nil
        case .hourly: .seconds(3600)
        case .quarterHour: .seconds(900)
        case .always: .seconds(60)
        }
    }

    static var current: MeasurementCadence {
        guard let raw = AppDefaults.store.string(forKey: defaultsKey),
              let cadence = MeasurementCadence(rawValue: raw) else {
            return .quarterHour
        }
        return cadence
    }
}

/// Keeps the current volume reading fresh for the menu bar and the panel.
@MainActor
@Observable
final class VolumeMonitor {
    private(set) var stats: VolumeStats?
    private(set) var lastError: String?
    private(set) var lastUpdate: Date?

    /// How often the reading refreshes while the app is open, independent of
    /// the background cadence. Cheap: one `statfs`.
    private let foregroundInterval: Duration = .seconds(30)

    var freeSpaceText: String {
        stats.map { Figure.bytes($0.available).joined } ?? "—"
    }

    var usedFraction: Double {
        stats?.usedFraction ?? 0
    }

    /// The volume's own name, as Finder shows it. Falls back to the mount
    /// point, which is at least true.
    var volumeName: String {
        guard let stats else { return "—" }
        let url = URL(filePath: stats.mountPoint)
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey]),
           let name = values.volumeName {
            return name
        }
        return stats.mountPoint
    }

    var cadenceDescription: String {
        String(localized: MeasurementCadence.current.sentence)
    }

    /// Mirrors the thresholds that mattered in practice: below five gigabytes
    /// tools start failing to write temporary files.
    var pressure: Pressure {
        guard let stats else { return .unknown }
        let freeGB = Double(stats.available.rawValue) / 1_000_000_000
        if freeGB < 5 { return .critical }
        if freeGB < 20 { return .low }
        return .comfortable
    }

    enum Pressure {
        case unknown, comfortable, low, critical
    }

    func refresh() {
        do {
            stats = try VolumeStats.forHomeVolume()
            lastUpdate = .now
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func start() async {
        refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: foregroundInterval)
            } catch {
                return
            }
            // `off` still measures once at launch so the menu bar has
            // something to show; what it stops is the repeating.
            guard MeasurementCadence.current != .off else { continue }
            refresh()
        }
    }
}
