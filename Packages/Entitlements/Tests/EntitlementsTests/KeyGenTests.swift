import CryptoKit
import Foundation
import Testing
@testable import Entitlements

/// Generates a development key pair and a licence. Opt-in, never part of a
/// normal test run. The production key is generated at M6 and lives in the
/// Keychain; this one exists only so the paid surfaces can be exercised.
@Suite("Key generation", .enabled(if: ProcessInfo.processInfo.environment["TORTU_GENKEY"] != nil))
struct KeyGenTests {
    @Test("Generate a development key pair and licence")
    func generate() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let issuer = LicenseIssuer(privateKey: privateKey)

        print("GENKEY_PRIVATE \(privateKey.rawRepresentation.base64EncodedString())")
        print("GENKEY_PUBLIC \(issuer.publicKeyRepresentation.base64EncodedString())")

        let license = License(
            licenseID: "TORTU-DEV-0001",
            issuedTo: "Development build",
            issued: Date(),
            expires: nil,
            entitlements: Entitlement.allCases
        )
        let signed = try issuer.sign(license)
        let encoded = try JSONEncoder().encode(signed)
        print("GENKEY_LICENSE \(encoded.base64EncodedString())")

        // The generated material must actually verify, or it is worthless.
        let verifier = try LicenseVerifier(
            publicKeyRepresentation: issuer.publicKeyRepresentation
        )
        #expect(try verifier.verify(signed).licenseID == "TORTU-DEV-0001")
    }
}
