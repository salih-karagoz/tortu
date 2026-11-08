import Foundation

/// Grants what a verified licence says and nothing else.
public struct LicensedEntitlements: EntitlementProviding {
    public let license: License
    private let granted: Set<Entitlement>

    public init(license: License) {
        self.license = license
        self.granted = Set(license.entitlements)
    }

    public func isUnlocked(_ entitlement: Entitlement) -> Bool {
        granted.contains(entitlement)
    }
}

/// Loads a licence at launch and falls back to the free build if anything is
/// wrong with it.
///
/// A licence that fails to verify never crashes the app and never silently
/// grants anything; it degrades to the free experience and records why, so
/// settings can tell the user what happened.
public struct EntitlementLoader: Sendable {
    public enum Outcome: Sendable {
        case free
        case licensed(License)
        case rejected(LicenseError)

        public var provider: any EntitlementProviding {
            switch self {
            case let .licensed(license): LicensedEntitlements(license: license)
            case .free, .rejected: FreeEntitlements()
            }
        }
    }

    private let verifier: LicenseVerifier

    public init(verifier: LicenseVerifier) {
        self.verifier = verifier
    }

    public func load(from url: URL?) -> Outcome {
        guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else {
            return .free
        }
        do {
            return .licensed(try verifier.verify(contentsOf: url))
        } catch let error as LicenseError {
            return .rejected(error)
        } catch {
            return .rejected(.malformed)
        }
    }
}
