import Foundation
import IOKit
import ScanCore

/// What the graphics processor is doing.
///
/// The accelerator publishes its own utilisation in the registry, so this is
/// read rather than estimated. A machine whose driver does not publish it
/// reports nothing at all, and the screen leaves the figure out instead of
/// showing a nought that would read as "idle".
public struct GPUReading: Sendable, Equatable {
    /// Busy fraction of the device, zero to one.
    public var utilisation: Double?
    public var rendererUtilisation: Double?
    public var tilerUtilisation: Double?
    /// System memory the graphics driver currently has in use. On Apple
    /// silicon this is the same memory everything else is competing for,
    /// which is why it is worth printing beside the other figures.
    public var memoryInUse: ByteCount?

    public init(
        utilisation: Double? = nil,
        rendererUtilisation: Double? = nil,
        tilerUtilisation: Double? = nil,
        memoryInUse: ByteCount? = nil
    ) {
        self.utilisation = utilisation
        self.rendererUtilisation = rendererUtilisation
        self.tilerUtilisation = tilerUtilisation
        self.memoryInUse = memoryInUse
    }

    public var isAvailable: Bool { utilisation != nil }
}

public struct GPUSampler: Sendable {
    public init() {}

    public func sample() -> GPUReading {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return GPUReading() }
        defer { IOObjectRelease(iterator) }

        var reading = GPUReading()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                let dictionary = properties?.takeRetainedValue() as? [String: Any],
                let statistics = dictionary["PerformanceStatistics"] as? [String: Any]
            else { continue }

            func percentage(_ key: String) -> Double? {
                guard let raw = statistics[key] as? Int else { return nil }
                return min(max(Double(raw) / 100, 0), 1)
            }

            // Several accelerators can be present; the busiest one is the
            // one the user is looking at the effect of.
            if let device = percentage("Device Utilization %"),
               device >= (reading.utilisation ?? -1) {
                reading.utilisation = device
                reading.rendererUtilisation = percentage("Renderer Utilization %")
                reading.tilerUtilisation = percentage("Tiler Utilization %")
                if let memory = statistics["In use system memory"] as? Int {
                    reading.memoryInUse = ByteCount(Int64(memory))
                }
            }
        }
        return reading
    }
}
