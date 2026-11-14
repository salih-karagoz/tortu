import Foundation
import IOKit
import IOKit.ps
import ScanCore

/// What the machine is running on, and how hard.
///
/// Deliberately not an "energy impact" score. macOS has one and it is a
/// weighting nobody outside Apple can reproduce; inventing a second one with
/// the same name would be the sort of plausible invention this application
/// exists to avoid. What is here instead is measured: where the power is
/// coming from, how much the battery is actually giving up, and how hot the
/// machine says it is.
public struct PowerReading: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case ac
        case battery
        case unknown
    }

    public var source: Source
    public var hasBattery: Bool
    /// Charge as a fraction of full.
    public var charge: Double?
    public var isCharging: Bool
    /// Seconds left, when the system is willing to estimate. It refuses for
    /// the first few minutes after a change, and the screen says so.
    public var timeRemaining: TimeInterval?
    /// Watts coming out of the battery, measured from its own current and
    /// voltage. Nil on mains, where the battery is not the thing supplying
    /// the machine and this figure would mean nothing.
    public var batteryWatts: Double?
    public var cycleCount: Int?
    /// What the battery still holds against what it was built to hold.
    public var health: Double?
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool

    public init(
        source: Source = .unknown,
        hasBattery: Bool = false,
        charge: Double? = nil,
        isCharging: Bool = false,
        timeRemaining: TimeInterval? = nil,
        batteryWatts: Double? = nil,
        cycleCount: Int? = nil,
        health: Double? = nil,
        thermal: ThermalLevel = .nominal,
        lowPowerMode: Bool = false
    ) {
        self.source = source
        self.hasBattery = hasBattery
        self.charge = charge
        self.isCharging = isCharging
        self.timeRemaining = timeRemaining
        self.batteryWatts = batteryWatts
        self.cycleCount = cycleCount
        self.health = health
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }
}

/// How hot the machine says it is, as the system itself grades it.
public enum ThermalLevel: Int, Sendable, Equatable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

public struct PowerSampler: Sendable {
    public init() {}

    public func sample() -> PowerReading {
        var reading = PowerReading(
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            let providing = IOPSGetProvidingPowerSourceType(blob)?
                .takeRetainedValue() as String?
            reading.source = switch providing {
            case kIOPMACPowerKey: .ac
            case kIOPMBatteryPowerKey: .battery
            default: .unknown
            }

            if let sources = IOPSCopyPowerSourcesList(blob)?
                .takeRetainedValue() as? [CFTypeRef] {
                for source in sources {
                    guard let description = IOPSGetPowerSourceDescription(blob, source)?
                        .takeUnretainedValue() as? [String: Any],
                        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                    else { continue }
                    reading.hasBattery = true
                    if let current = description[kIOPSCurrentCapacityKey] as? Int,
                       let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                        reading.charge = Double(current) / Double(maximum)
                    }
                    reading.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
                    let minutes = reading.isCharging
                        ? description[kIOPSTimeToFullChargeKey] as? Int
                        : description[kIOPSTimeToEmptyKey] as? Int
                    // The system answers −1 while it is still working the
                    // estimate out, and 0 when there is nothing to estimate.
                    if let minutes, minutes > 0 {
                        reading.timeRemaining = TimeInterval(minutes) * 60
                    }
                }
            }
        }

        applySmartBattery(to: &reading)
        return reading
    }

    /// The battery's own registry entry, for the figures the power-source
    /// summary leaves out.
    private func applySmartBattery(to reading: inout PowerReading) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return }

        reading.hasBattery = reading.hasBattery
            || (dictionary["BatteryInstalled"] as? Bool ?? false)
        if let cycles = dictionary["CycleCount"] as? Int { reading.cycleCount = cycles }
        if let maximum = dictionary["AppleRawMaxCapacity"] as? Int,
           let design = dictionary["DesignCapacity"] as? Int, design > 0 {
            reading.health = Double(maximum) / Double(design)
        }

        // Current is in milliamps and signed: negative while the battery is
        // supplying the machine. Only that direction is a draw, and only
        // while the machine is off mains — a plugged-in battery dips in and
        // out of discharge by a few hundred milliwatts, and printing that
        // beside the word "mains" would be a contradiction rather than a
        // reading.
        let onMains = dictionary["ExternalConnected"] as? Bool ?? (reading.source == .ac)
        if !onMains,
           let milliamps = dictionary["InstantAmperage"] as? Int ?? dictionary["Amperage"] as? Int,
           let millivolts = dictionary["Voltage"] as? Int, millivolts > 0, milliamps < 0 {
            reading.batteryWatts = Double(-milliamps) * Double(millivolts) / 1_000_000
        }
    }
}
