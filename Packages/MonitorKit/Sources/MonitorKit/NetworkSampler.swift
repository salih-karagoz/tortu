import Darwin
import Foundation
import ScanCore

/// One network interface's byte counters as the kernel hands them over.
///
/// The byte counters are thirty-two bits wide and wrap: this machine's
/// loopback had been round six times and its Wi-Fi nineteen by the time this
/// was written, so the raw figure is useless as a total and perfectly good as
/// a difference. Nothing here is ever presented as a lifetime total; what the
/// screen shows is the rate, and a running total this application has watched
/// accumulate itself.
public struct InterfaceCounters: Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: InterfaceKind
    public var bytesIn: UInt32
    public var bytesOut: UInt32
    public var packetsIn: UInt64
    public var packetsOut: UInt64

    public var id: String { name }

    public init(
        name: String,
        kind: InterfaceKind,
        bytesIn: UInt32,
        bytesOut: UInt32,
        packetsIn: UInt64 = 0,
        packetsOut: UInt64 = 0
    ) {
        self.name = name
        self.kind = kind
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
    }
}

/// What an interface is, so the screen can tell traffic that left the machine
/// from traffic that never did.
///
/// Loopback is the clearest case: `lo0` carries every local connection and is
/// routinely the busiest interface on the machine, and adding it to a
/// "downloaded" figure would be a lie. It is counted, shown and kept apart.
public enum InterfaceKind: String, Sendable, Equatable, CaseIterable {
    case physical
    case loopback
    case virtual
}

/// One interface's traffic over an interval.
public struct InterfaceReading: Sendable, Equatable, Identifiable {
    public var counters: InterfaceCounters
    public var inPerSecond: Double
    public var outPerSecond: Double
    /// What this interface has carried since the screen started watching.
    public var sessionIn: ByteCount
    public var sessionOut: ByteCount

    public var id: String { counters.name }
    public var name: String { counters.name }
    public var kind: InterfaceKind { counters.kind }

    public init(
        counters: InterfaceCounters,
        inPerSecond: Double = 0,
        outPerSecond: Double = 0,
        sessionIn: ByteCount = .zero,
        sessionOut: ByteCount = .zero
    ) {
        self.counters = counters
        self.inPerSecond = inPerSecond
        self.outPerSecond = outPerSecond
        self.sessionIn = sessionIn
        self.sessionOut = sessionOut
    }
}

/// The whole machine's traffic, with the interfaces it was made up of.
public struct NetworkReading: Sendable, Equatable {
    public var interfaces: [InterfaceReading]

    public init(interfaces: [InterfaceReading]) {
        self.interfaces = interfaces
    }

    public static let silent = NetworkReading(interfaces: [])

    private var external: [InterfaceReading] {
        interfaces.filter { $0.kind != .loopback }
    }

    /// Traffic that actually left the machine: everything but loopback.
    public var inPerSecond: Double { external.reduce(0) { $0 + $1.inPerSecond } }
    public var outPerSecond: Double { external.reduce(0) { $0 + $1.outPerSecond } }
    public var sessionIn: ByteCount { external.reduce(ByteCount.zero) { $0 + $1.sessionIn } }
    public var sessionOut: ByteCount { external.reduce(ByteCount.zero) { $0 + $1.sessionOut } }

    /// The interfaces worth printing: the ones carrying something now, or
    /// that have carried something since the screen opened.
    public var active: [InterfaceReading] {
        interfaces
            .filter {
                $0.inPerSecond + $0.outPerSecond > 0
                    || $0.sessionIn.rawValue + $0.sessionOut.rawValue > 0
            }
            .sorted {
                ($0.inPerSecond + $0.outPerSecond, $0.sessionIn.rawValue + $0.sessionOut.rawValue)
                    > ($1.inPerSecond + $1.outPerSecond, $1.sessionIn.rawValue + $1.sessionOut.rawValue)
            }
    }
}

/// Keeps the previous round of counters, so a wrapping thirty-two bit figure
/// can still be turned into a rate and a running total.
public struct NetworkAccumulator: Sendable {
    private var previous: [String: InterfaceCounters] = [:]
    private var session: [String: (in: Int64, out: Int64)] = [:]

    public init() {}

    public mutating func reset() {
        previous = [:]
        session = [:]
    }

    /// The most one interface is taken to carry in a second before a
    /// backwards step stops looking like a wrap. Twice a ten-gigabit link,
    /// which no interface on a laptop sustains for a whole second.
    static let plausibleBytesPerSecond: Double = 2_000_000_000

    /// The bytes that passed between two readings of a counter that wraps.
    ///
    /// Unsigned subtraction is the right answer modulo two to the thirty-two,
    /// so a wrap needs no special case. A counter that was *restarted* looks
    /// identical to that subtraction and is not the same thing: an interface
    /// taken down and brought back under the same name — a VPN reconnecting
    /// as `utun4` — begins again at nought, and the subtraction then reports
    /// nearly four gigabytes in one tick. That is a rate of several gigabytes
    /// a second on screen and a session total that stays wrong for as long as
    /// the screen is open.
    ///
    /// So a backwards step is read as a wrap only when a wrap could have
    /// carried that many bytes in the time available, and as a restart
    /// otherwise. Where the ceiling is wrong the cost is one counter's worth
    /// undercounted on a genuine wrap, which is the smaller of the two errors
    /// and the quieter one.
    static func passed(
        _ now: UInt32, since previous: UInt32, interval: TimeInterval
    ) -> UInt32 {
        if now >= previous { return now - previous }
        let wrapped = now &- previous
        return Double(wrapped) <= plausibleBytesPerSecond * max(interval, 0) ? wrapped : now
    }

    public mutating func reading(
        from counters: [InterfaceCounters], interval: TimeInterval
    ) -> NetworkReading {
        var readings: [InterfaceReading] = []
        readings.reserveCapacity(counters.count)

        for current in counters {
            guard let before = previous[current.name], interval > 0 else {
                readings.append(InterfaceReading(counters: current))
                continue
            }
            let received = Self.passed(
                current.bytesIn, since: before.bytesIn, interval: interval
            )
            let sent = Self.passed(
                current.bytesOut, since: before.bytesOut, interval: interval
            )
            var totals = session[current.name] ?? (in: 0, out: 0)
            totals.in += Int64(received)
            totals.out += Int64(sent)
            session[current.name] = totals
            readings.append(InterfaceReading(
                counters: current,
                inPerSecond: Double(received) / interval,
                outPerSecond: Double(sent) / interval,
                sessionIn: ByteCount(totals.in),
                sessionOut: ByteCount(totals.out)
            ))
        }

        previous = Dictionary(
            counters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return NetworkReading(interfaces: readings)
    }
}

/// Reads the per-interface byte counters the kernel keeps.
public struct NetworkSampler: Sendable {
    public init() {}

    public func sample() -> [InterfaceCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceCounters] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            // Only the link-layer entry carries the counters; the IPv4 and
            // IPv6 entries for the same interface carry addresses.
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let payload = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let data = payload.assumingMemoryBound(to: if_data.self).pointee
            result.append(InterfaceCounters(
                name: name,
                kind: Self.kind(of: name, type: data.ifi_type),
                bytesIn: data.ifi_ibytes,
                bytesOut: data.ifi_obytes,
                packetsIn: UInt64(data.ifi_ipackets),
                packetsOut: UInt64(data.ifi_opackets)
            ))
        }
        return result
    }

    static func kind(of name: String, type: UInt8) -> InterfaceKind {
        if type == UInt8(IFT_LOOP) || name.hasPrefix("lo") { return .loopback }
        // Tunnels, AirDrop's own link, bridges and the virtualisation
        // interfaces are all real traffic, but none of it is the Wi-Fi or
        // Ethernet the user means by "the network".
        for prefix in ["utun", "ipsec", "awdl", "llw", "bridge", "gif", "stf", "ap", "anpi", "vmenet"]
            where name.hasPrefix(prefix) {
            return .virtual
        }
        return .physical
    }
}
