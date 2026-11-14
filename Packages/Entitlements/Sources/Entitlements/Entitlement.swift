import Foundation

/// A capability that could be gated behind a licence.
///
/// Nothing is sold. Tortu ships as one build, Apache-2.0, with every
/// capability in it, so every answer here is yes and `OpenEntitlements` is
/// what the application links.
///
/// The mechanism stays, because whether to sell is a product decision rather
/// than a technical one and it should be reversible in a line rather than
/// rebuilt from nothing. Two rules hold whatever that decision turns out to
/// be:
///
/// - Only a capability with a real gate in the code appears here. A case with
///   no call site is a plan, and a plan does not belong in a type that claims
///   to describe what the application does.
/// - Nothing security-critical appears here, ever. The privileged helper and
///   every rule that deletes a file stay in the open build, so the code that
///   runs as root remains auditable by anyone.
public enum Entitlement: String, Sendable, CaseIterable, Codable {
    /// Watching the volume while the application is closed, and the threshold
    /// notifications that depend on that watch.
    case backgroundMonitoring
    /// The live instrument: processor, memory, processes, energy, disk and
    /// network, measured as they happen rather than once a quarter of an hour.
    /// Nothing it does removes anything.
    case liveActivity
}

/// Answers whether a capability is unlocked.
///
/// The application links `OpenEntitlements`, which always answers yes. The
/// other two implementations exist for tests, for previews, and for capturing
/// what a locked screen would look like.
public protocol EntitlementProviding: Sendable {
    func isUnlocked(_ entitlement: Entitlement) -> Bool
}

public extension EntitlementProviding {
    var unlockedEntitlements: Set<Entitlement> {
        Set(Entitlement.allCases.filter(isUnlocked))
    }

    var hasAnyPaidEntitlement: Bool {
        Entitlement.allCases.contains(where: isUnlocked)
    }
}

/// The provider the application links: everything is unlocked, because
/// everything is given away.
///
/// This is the one place that decides. Every gate in the application still
/// asks, so turning the decision around later means changing this line rather
/// than finding each gate again.
public struct OpenEntitlements: EntitlementProviding {
    public init() {}

    public func isUnlocked(_ entitlement: Entitlement) -> Bool { true }
}

/// A provider that unlocks nothing.
public struct FreeEntitlements: EntitlementProviding {
    public init() {}

    public func isUnlocked(_ entitlement: Entitlement) -> Bool { false }
}

/// A provider for tests and previews.
public struct FixedEntitlements: EntitlementProviding {
    private let unlocked: Set<Entitlement>

    public init(unlocked: Set<Entitlement>) {
        self.unlocked = unlocked
    }

    public static let everything = FixedEntitlements(unlocked: Set(Entitlement.allCases))

    public func isUnlocked(_ entitlement: Entitlement) -> Bool {
        unlocked.contains(entitlement)
    }
}
