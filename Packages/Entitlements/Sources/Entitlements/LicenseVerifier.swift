import CryptoKit
import Foundation

/// Checks a licence against a public key compiled into the application.
///
/// Verification is offline on purpose. A licence server would mean the app
/// phones home to decide whether it may run, which for a tool people install
/// to clean their own disk is both a privacy cost and an outage waiting to
/// happen. Ed25519 signatures let the check happen on the user's machine with
/// nothing to contact.
public struct LicenseVerifier: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey
    private let now: @Sendable () -> Date

    public init(
        publicKeyRepresentation: Data,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRepresentation)
        self.now = now
    }

    public func verify(_ signed: SignedLicense) throws -> License {
        guard publicKey.isValidSignature(signed.signature, for: signed.payload) else {
            throw LicenseError.invalidSignature
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let license = try? decoder.decode(License.self, from: signed.payload) else {
            throw LicenseError.malformed
        }

        guard license.formatVersion <= License.currentFormatVersion else {
            throw LicenseError.unsupportedFormat(version: license.formatVersion)
        }
        if let expires = license.expires, expires < now() {
            throw LicenseError.expired(on: expires)
        }
        return license
    }

    /// Reads a licence from the file the user was sent.
    public func verify(contentsOf url: URL) throws -> License {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        guard let signed = try? decoder.decode(SignedLicense.self, from: data) else {
            throw LicenseError.malformed
        }
        return try verify(signed)
    }
}

/// Signs licences. Ships with the seller, never with the application.
///
/// It lives here so that the signing and verifying sides cannot drift apart,
/// and so the round trip is covered by the same tests. The private key is not
/// in this repository and must never be.
public struct LicenseIssuer: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public var publicKeyRepresentation: Data {
        privateKey.publicKey.rawRepresentation
    }

    public func sign(_ license: License) throws -> SignedLicense {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(license)
        return SignedLicense(
            payload: payload,
            signature: try privateKey.signature(for: payload)
        )
    }
}
