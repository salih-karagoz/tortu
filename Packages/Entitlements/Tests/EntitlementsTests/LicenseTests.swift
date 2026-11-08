import CryptoKit
import Foundation
import Testing
@testable import Entitlements

@Suite("Licensing")
struct LicenseTests {
    static let issuer = LicenseIssuer(privateKey: Curve25519.Signing.PrivateKey())
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func verifier(
        key: Data = issuer.publicKeyRepresentation,
        at date: Date = now
    ) throws -> LicenseVerifier {
        try LicenseVerifier(publicKeyRepresentation: key, now: { date })
    }

    static func license(
        expires: Date? = nil,
        entitlements: [Entitlement] = [.history, .growthCharts]
    ) -> License {
        License(
            licenseID: "TORTU-0001", issuedTo: "A Person",
            issued: now.addingTimeInterval(-86_400),
            expires: expires, entitlements: entitlements
        )
    }

    @Test("A signed licence verifies and keeps its contents")
    func roundTrip() throws {
        let signed = try Self.issuer.sign(Self.license())
        let verified = try Self.verifier().verify(signed)

        #expect(verified.licenseID == "TORTU-0001")
        #expect(verified.issuedTo == "A Person")
        #expect(Set(verified.entitlements) == [.history, .growthCharts])
    }

    @Test("A tampered payload fails verification")
    func tamperedPayload() throws {
        let signed = try Self.issuer.sign(Self.license(entitlements: [.history]))

        // Swap in a payload that grants everything, keeping the old signature.
        let greedy = try JSONEncoder.iso8601Sorted.encode(
            Self.license(entitlements: Entitlement.allCases)
        )
        let forged = SignedLicense(payload: greedy, signature: signed.signature)

        #expect(throws: LicenseError.invalidSignature) {
            try Self.verifier().verify(forged)
        }
    }

    @Test("A signature from another key is refused")
    func wrongKey() throws {
        let signed = try Self.issuer.sign(Self.license())
        let stranger = LicenseIssuer(privateKey: Curve25519.Signing.PrivateKey())

        #expect(throws: LicenseError.invalidSignature) {
            try Self.verifier(key: stranger.publicKeyRepresentation).verify(signed)
        }
    }

    @Test("An expired licence is refused")
    func expired() throws {
        let yesterday = Self.now.addingTimeInterval(-86_400)
        let signed = try Self.issuer.sign(Self.license(expires: yesterday))

        #expect(throws: LicenseError.expired(on: yesterday)) {
            try Self.verifier().verify(signed)
        }
    }

    @Test("A licence expiring in the future is accepted")
    func notYetExpired() throws {
        let signed = try Self.issuer.sign(
            Self.license(expires: Self.now.addingTimeInterval(86_400))
        )
        #expect(try Self.verifier().verify(signed).licenseID == "TORTU-0001")
    }

    @Test("A perpetual licence never expires")
    func perpetual() throws {
        let signed = try Self.issuer.sign(Self.license(expires: nil))
        let farFuture = Self.now.addingTimeInterval(86_400 * 365 * 50)
        #expect(try Self.verifier(at: farFuture).verify(signed).expires == nil)
    }

    @Test("A licence from a newer format is refused rather than guessed at")
    func futureFormat() throws {
        let future = License(
            licenseID: "X", issuedTo: "Y", issued: Self.now,
            entitlements: [.history], formatVersion: 99
        )
        let signed = try Self.issuer.sign(future)
        #expect(throws: LicenseError.unsupportedFormat(version: 99)) {
            try Self.verifier().verify(signed)
        }
    }

    @Test("Garbage in place of a payload is refused")
    func malformedPayload() throws {
        let key = Curve25519.Signing.PrivateKey()
        let garbage = Data("not json".utf8)
        let signed = SignedLicense(
            payload: garbage, signature: try key.signature(for: garbage)
        )
        #expect(throws: LicenseError.malformed) {
            try Self.verifier(key: key.publicKey.rawRepresentation).verify(signed)
        }
    }

    @Test("A verified licence grants exactly what it lists")
    func grantsListedEntitlementsOnly() throws {
        let signed = try Self.issuer.sign(Self.license(entitlements: [.history]))
        let provider = LicensedEntitlements(license: try Self.verifier().verify(signed))

        #expect(provider.isUnlocked(.history))
        #expect(!provider.isUnlocked(.duplicateFinder))
        #expect(provider.unlockedEntitlements == [.history])
    }
}

@Suite("Entitlement loading")
struct EntitlementLoaderTests {
    @Test("No licence file means the free build")
    func noFile() throws {
        let loader = EntitlementLoader(verifier: try LicenseTests.verifier())
        let outcome = loader.load(from: nil)
        if case .free = outcome {} else { Issue.record("expected the free outcome") }
        #expect(!outcome.provider.hasAnyPaidEntitlement)
    }

    @Test("A rejected licence degrades to free instead of crashing")
    func rejectedLicenceDegrades() throws {
        let url = URL.temporaryDirectory.appending(path: "bad-\(UUID().uuidString).tortulicense")
        try Data("{\"nonsense\":true}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = EntitlementLoader(verifier: try LicenseTests.verifier()).load(from: url)
        guard case let .rejected(error) = outcome else {
            Issue.record("expected the licence to be rejected")
            return
        }
        #expect(error == .malformed)
        #expect(!outcome.provider.hasAnyPaidEntitlement)
    }

    @Test("A valid licence file unlocks what it grants")
    func validFileUnlocks() throws {
        let signed = try LicenseTests.issuer.sign(LicenseTests.license())
        let url = URL.temporaryDirectory.appending(path: "ok-\(UUID().uuidString).tortulicense")
        try JSONEncoder().encode(signed).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = EntitlementLoader(verifier: try LicenseTests.verifier()).load(from: url)
        guard case .licensed = outcome else {
            Issue.record("expected the licence to be accepted")
            return
        }
        #expect(outcome.provider.isUnlocked(.growthCharts))
        #expect(!outcome.provider.isUnlocked(.ruleSync))
    }
}

extension JSONEncoder {
    static var iso8601Sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
