import Foundation

/// A capability that may be gated behind a paid licence.
///
/// Nothing security-critical appears here by design. The privileged helper and
/// every rule that deletes files stay in the free, open build, so that the code
/// running as root remains auditable by anyone. What is sold is depth and
/// automation, not the ability to clean safely.
public enum Entitlement: String, Sendable, CaseIterable, Codable {
    case history
    case growthCharts
    case backgroundMonitoring
    case scheduledProfiles
    case duplicateFinder
    case applicationUninstaller
    case ruleSync
}

/// Answers whether a capability is unlocked.
///
/// The free build links `FreeEntitlements`, which always answers no. The Pro
/// build links an implementation that verifies an Ed25519-signed licence file
/// offline, with the public key compiled in; no licence server is involved.
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

/// The provider compiled into the free build.
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
